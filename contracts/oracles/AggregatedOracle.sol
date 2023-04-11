//SPDX-License-Identifier: MIT
pragma solidity =0.8.13;

import "@openzeppelin-v4/contracts/utils/math/SafeCast.sol";
import "@openzeppelin-v4/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "./PeriodicOracle.sol";
import "../interfaces/IAggregatedOracle.sol";
import "../interfaces/IHistoricalOracle.sol";
import "../libraries/SafeCastExt.sol";
import "../libraries/uniswap-lib/FullMath.sol";
import "../utils/ExplicitQuotationMetadata.sol";
import "../strategies/aggregation/IAggregationStrategy.sol";

contract AggregatedOracle is IAggregatedOracle, IHistoricalOracle, PeriodicOracle, ExplicitQuotationMetadata {
    using SafeCast for uint256;
    using SafeCastExt for uint256;

    struct TokenSpecificOracle {
        address token;
        address oracle;
    }

    struct OracleConfig {
        address oracle;
        uint8 quoteTokenDecimals;
        uint8 liquidityDecimals;
    }

    struct BufferMetadata {
        uint16 start;
        uint16 end;
        uint16 size;
        uint16 maxSize;
    }

    IAggregationStrategy public immutable aggregationStrategy;

    /// @notice The minimum quote token denominated value of the token liquidity, scaled by this oracle's liquidity
    /// decimals, required for all underlying oracles to be considered valid and thus included in the aggregation.
    uint256 public immutable minimumTokenLiquidityValue;

    /// @notice The minimum quote token liquidity, scaled by this oracle's liquidity decimals, required for all
    /// underlying oracles to be considered valid and thus included in the aggregation.
    uint256 public immutable minimumQuoteTokenLiquidity;

    mapping(address => BufferMetadata) internal observationBufferMetadata;

    mapping(address => ObservationLibrary.Observation[]) internal observationBuffers;

    /// @notice One whole unit of the quote token, in the quote token's smallest denomination.
    uint256 internal immutable _quoteTokenWholeUnit;

    uint8 internal immutable _liquidityDecimals;

    uint16 internal immutable _initialCardinality;

    OracleConfig[] internal oracles;
    mapping(address => OracleConfig[]) internal tokenSpecificOracles;

    mapping(address => bool) private oracleExists;
    mapping(address => mapping(address => bool)) private oracleForExists;

    /// @notice Event emitted when an observation buffer's capacity is increased past the initial capacity.
    /// @dev Buffer initialization does not emit an event.
    /// @param token The token for which the observation buffer's capacity was increased.
    /// @param oldCapacity The previous capacity of the observation buffer.
    /// @param newCapacity The new capacity of the observation buffer.
    event ObservationCapacityIncreased(address indexed token, uint256 oldCapacity, uint256 newCapacity);

    /// @notice Event emitted when an observation buffer's capacity is initialized.
    /// @param token The token for which the observation buffer's capacity was initialized.
    /// @param capacity The capacity of the observation buffer.
    event ObservationCapacityInitialized(address indexed token, uint256 capacity);

    struct AggregatedOracleParams {
        IAggregationStrategy aggregationStrategy;
        string quoteTokenName;
        address quoteTokenAddress;
        string quoteTokenSymbol;
        uint8 quoteTokenDecimals;
        uint8 liquidityDecimals;
        address[] oracles;
        TokenSpecificOracle[] tokenSpecificOracles;
        uint256 period;
        uint256 granularity;
        uint256 minimumTokenLiquidityValue;
        uint256 minimumQuoteTokenLiquidity;
    }

    constructor(
        AggregatedOracleParams memory params
    )
        PeriodicOracle(params.quoteTokenAddress, params.period, params.granularity)
        ExplicitQuotationMetadata(
            params.quoteTokenName,
            params.quoteTokenAddress,
            params.quoteTokenSymbol,
            params.quoteTokenDecimals
        )
    {
        require(
            params.oracles.length > 0 || params.tokenSpecificOracles.length > 0,
            "AggregatedOracle: MISSING_ORACLES"
        );

        aggregationStrategy = params.aggregationStrategy;

        minimumTokenLiquidityValue = params.minimumTokenLiquidityValue;
        minimumQuoteTokenLiquidity = params.minimumQuoteTokenLiquidity;

        _quoteTokenWholeUnit = 10 ** params.quoteTokenDecimals;

        _liquidityDecimals = params.liquidityDecimals;

        // Setup general oracles
        for (uint256 i = 0; i < params.oracles.length; ++i) {
            require(!oracleExists[params.oracles[i]], "AggregatedOracle: DUPLICATE_ORACLE");

            oracleExists[params.oracles[i]] = true;

            oracles.push(
                OracleConfig({
                    oracle: params.oracles[i],
                    quoteTokenDecimals: IOracle(params.oracles[i]).quoteTokenDecimals(),
                    liquidityDecimals: IOracle(params.oracles[i]).liquidityDecimals()
                })
            );
        }

        // Setup token-specific oracles
        for (uint256 i = 0; i < params.tokenSpecificOracles.length; ++i) {
            TokenSpecificOracle memory oracle = params.tokenSpecificOracles[i];

            require(!oracleExists[oracle.oracle], "AggregatedOracle: DUPLICATE_ORACLE");
            require(!oracleForExists[oracle.token][oracle.oracle], "AggregatedOracle: DUPLICATE_ORACLE");

            oracleForExists[oracle.token][oracle.oracle] = true;

            tokenSpecificOracles[oracle.token].push(
                OracleConfig({
                    oracle: oracle.oracle,
                    quoteTokenDecimals: IOracle(oracle.oracle).quoteTokenDecimals(),
                    liquidityDecimals: IOracle(oracle.oracle).liquidityDecimals()
                })
            );
        }

        _initialCardinality = 1;
    }

    /// @inheritdoc IAggregatedOracle
    function getOracles() external view virtual override returns (address[] memory) {
        OracleConfig[] memory _oracles = oracles;

        address[] memory allOracles = new address[](_oracles.length);

        // Add the general oracles
        for (uint256 i = 0; i < _oracles.length; ++i) allOracles[i] = _oracles[i].oracle;

        return allOracles;
    }

    /// @inheritdoc IAggregatedOracle
    function getOraclesFor(address token) external view virtual override returns (address[] memory) {
        OracleConfig[] memory _tokenSpecificOracles = tokenSpecificOracles[token];
        OracleConfig[] memory _oracles = oracles;

        address[] memory allOracles = new address[](_oracles.length + _tokenSpecificOracles.length);

        // Add the general oracles
        for (uint256 i = 0; i < _oracles.length; ++i) allOracles[i] = _oracles[i].oracle;

        // Add the token specific oracles
        for (uint256 i = 0; i < _tokenSpecificOracles.length; ++i)
            allOracles[_oracles.length + i] = _tokenSpecificOracles[i].oracle;

        return allOracles;
    }

    /// @inheritdoc IHistoricalOracle
    function getObservationAt(
        address token,
        uint256 index
    ) external view virtual override returns (ObservationLibrary.Observation memory) {
        BufferMetadata memory meta = observationBufferMetadata[token];

        require(index < meta.size, "AggregatedOracle: INVALID_INDEX");

        uint256 bufferIndex = meta.end < index ? meta.end + meta.size - index : meta.end - index;

        return observationBuffers[token][bufferIndex];
    }

    /// @inheritdoc IHistoricalOracle
    function getObservations(
        address token,
        uint256 amount
    ) external view virtual override returns (ObservationLibrary.Observation[] memory) {
        return getObservationsInternal(token, amount, 0, 1);
    }

    /// @inheritdoc IHistoricalOracle
    function getObservations(
        address token,
        uint256 amount,
        uint256 offset,
        uint256 increment
    ) external view virtual returns (ObservationLibrary.Observation[] memory) {
        return getObservationsInternal(token, amount, offset, increment);
    }

    /// @inheritdoc IHistoricalOracle
    function getObservationsCount(address token) external view override returns (uint256) {
        return observationBufferMetadata[token].size;
    }

    /// @inheritdoc IHistoricalOracle
    function getObservationsCapacity(address token) external view virtual override returns (uint256) {
        uint256 maxSize = observationBufferMetadata[token].maxSize;
        if (maxSize == 0) return _initialCardinality;

        return maxSize;
    }

    /// @inheritdoc IHistoricalOracle
    /// @param amount The new capacity of observations for the token. Must be greater than the current capacity, but
    ///   less than 65536.
    function setObservationsCapacity(address token, uint256 amount) external virtual override {
        BufferMetadata storage meta = observationBufferMetadata[token];
        if (meta.maxSize == 0) {
            // Buffer is not initialized yet
            initializeBuffers(token);
        }

        require(amount >= meta.maxSize, "AggregatedOracle: CAPACITY_CANNOT_BE_DECREASED");
        require(amount <= type(uint16).max, "AggregatedOracle: CAPACITY_TOO_LARGE");

        ObservationLibrary.Observation[] storage observationBuffer = observationBuffers[token];

        // Add new slots to the buffer
        uint256 capacityToAdd = amount - meta.maxSize;
        for (uint256 i = 0; i < capacityToAdd; ++i) {
            // Push a dummy observation with non-zero values to put most of the gas cost on the caller
            observationBuffer.push(
                ObservationLibrary.Observation({price: 1, tokenLiquidity: 1, quoteTokenLiquidity: 1, timestamp: 1})
            );
        }

        if (meta.maxSize != amount) {
            emit ObservationCapacityIncreased(token, meta.maxSize, amount);

            // Update the metadata
            meta.maxSize = uint16(amount);
        }
    }

    /// @inheritdoc ExplicitQuotationMetadata
    function quoteTokenName()
        public
        view
        virtual
        override(ExplicitQuotationMetadata, IQuoteToken, SimpleQuotationMetadata)
        returns (string memory)
    {
        return ExplicitQuotationMetadata.quoteTokenName();
    }

    /// @inheritdoc ExplicitQuotationMetadata
    function quoteTokenAddress()
        public
        view
        virtual
        override(ExplicitQuotationMetadata, IQuoteToken, SimpleQuotationMetadata)
        returns (address)
    {
        return ExplicitQuotationMetadata.quoteTokenAddress();
    }

    /// @inheritdoc ExplicitQuotationMetadata
    function quoteTokenSymbol()
        public
        view
        virtual
        override(ExplicitQuotationMetadata, IQuoteToken, SimpleQuotationMetadata)
        returns (string memory)
    {
        return ExplicitQuotationMetadata.quoteTokenSymbol();
    }

    /// @inheritdoc ExplicitQuotationMetadata
    function quoteTokenDecimals()
        public
        view
        virtual
        override(ExplicitQuotationMetadata, IQuoteToken, SimpleQuotationMetadata)
        returns (uint8)
    {
        return ExplicitQuotationMetadata.quoteTokenDecimals();
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(PeriodicOracle, ExplicitQuotationMetadata) returns (bool) {
        return
            interfaceId == type(IAggregatedOracle).interfaceId ||
            interfaceId == type(IHistoricalOracle).interfaceId ||
            ExplicitQuotationMetadata.supportsInterface(interfaceId) ||
            PeriodicOracle.supportsInterface(interfaceId);
    }

    /// @inheritdoc PeriodicOracle
    function canUpdate(bytes memory data) public view virtual override(IUpdateable, PeriodicOracle) returns (bool) {
        address token = abi.decode(data, (address));

        // If the parent contract can't update, this contract can't update
        if (!super.canUpdate(data)) return false;

        // Ensure all underlying oracles are up-to-date
        for (uint256 j = 0; j < 2; ++j) {
            OracleConfig[] memory _oracles;

            if (j == 0) _oracles = oracles;
            else _oracles = tokenSpecificOracles[token];

            for (uint256 i = 0; i < _oracles.length; ++i) {
                if (IOracle(_oracles[i].oracle).canUpdate(data)) {
                    // We can update one of the underlying oracles
                    return true;
                }
            }
        }

        (, uint256 validResponses) = aggregateUnderlying(token, calculateMaxAge());

        // Only return true if we have reached the minimum number of valid underlying oracle consultations
        return validResponses >= minimumResponses();
    }

    /// @inheritdoc IOracle
    function liquidityDecimals() public view virtual override returns (uint8) {
        return _liquidityDecimals;
    }

    function getLatestObservation(
        address token
    ) public view virtual override returns (ObservationLibrary.Observation memory observation) {
        BufferMetadata storage meta = observationBufferMetadata[token];

        if (meta.size == 0) {
            // If the buffer is empty, return the default observation
            return ObservationLibrary.Observation({price: 0, tokenLiquidity: 0, quoteTokenLiquidity: 0, timestamp: 0});
        }

        return observationBuffers[token][meta.end];
    }

    function getObservationsInternal(
        address token,
        uint256 amount,
        uint256 offset,
        uint256 increment
    ) internal view virtual returns (ObservationLibrary.Observation[] memory) {
        if (amount == 0) return new ObservationLibrary.Observation[](0);

        BufferMetadata memory meta = observationBufferMetadata[token];
        require(meta.size > (amount - 1) * increment + offset, "AggregatedOracle: INSUFFICIENT_DATA");

        ObservationLibrary.Observation[] memory observations = new ObservationLibrary.Observation[](amount);

        uint256 count = 0;

        for (
            uint256 i = meta.end < offset ? meta.end + meta.size - offset : meta.end - offset;
            count < amount;
            i = (i < increment) ? (i + meta.size) - increment : i - increment
        ) {
            observations[count++] = observationBuffers[token][i];
        }

        return observations;
    }

    function initializeBuffers(address token) internal virtual {
        require(
            observationBuffers[token].length == 0 && observationBuffers[token].length == 0,
            "AggregatedOracle: ALREADY_INITIALIZED"
        );

        BufferMetadata storage meta = observationBufferMetadata[token];

        // Initialize the buffers
        ObservationLibrary.Observation[] storage observationBuffer = observationBuffers[token];

        for (uint256 i = 0; i < _initialCardinality; ++i) {
            observationBuffer.push();
        }

        // Initialize the metadata
        meta.start = 0;
        meta.end = 0;
        meta.size = 0;
        meta.maxSize = _initialCardinality;

        emit ObservationCapacityInitialized(token, meta.maxSize);
    }

    function push(address token, ObservationLibrary.Observation memory observation) internal virtual {
        BufferMetadata storage meta = observationBufferMetadata[token];

        if (meta.size == 0) {
            if (meta.maxSize == 0) {
                // Initialize the buffers
                initializeBuffers(token);
            }
        } else {
            meta.end = (meta.end + 1) % meta.maxSize;
        }

        observationBuffers[token][meta.end] = observation;

        emit Updated(
            token,
            observation.price,
            observation.tokenLiquidity,
            observation.quoteTokenLiquidity,
            block.timestamp
        );

        if (meta.size < meta.maxSize && meta.end == meta.size) {
            // We are at the end of the array and we have not yet filled it
            meta.size++;
        } else {
            // start was just overwritten
            meta.start = (meta.start + 1) % meta.size;
        }
    }

    function performUpdate(bytes memory data) internal override returns (bool) {
        bool underlyingUpdated;
        address token = abi.decode(data, (address));

        // Ensure all underlying oracles are up-to-date
        for (uint256 j = 0; j < 2; ++j) {
            OracleConfig[] memory _oracles;

            if (j == 0) _oracles = oracles;
            else _oracles = tokenSpecificOracles[token];

            for (uint256 i = 0; i < _oracles.length; ++i) {
                // We don't want any problematic underlying oracles to prevent this oracle from updating
                // so we put update in a try-catch block
                try IOracle(_oracles[i].oracle).update(data) returns (bool updated) {
                    underlyingUpdated = underlyingUpdated || updated;
                } catch Error(string memory reason) {
                    emit UpdateErrorWithReason(_oracles[i].oracle, token, reason);
                } catch (bytes memory err) {
                    emit UpdateError(_oracles[i].oracle, token, err);
                }
            }
        }

        (ObservationLibrary.Observation memory observation, uint256 validResponses) = aggregateUnderlying(
            token,
            calculateMaxAge()
        );

        if (validResponses >= minimumResponses()) {
            push(token, observation);

            return true;
        } else emit UpdateErrorWithReason(address(this), token, "AggregatedOracle: INVALID_NUM_CONSULTATIONS");

        return underlyingUpdated;
    }

    /**
     * @notice The minimum number of valid underlying oracle consultations required to perform an update.
     */
    function minimumResponses() internal view virtual returns (uint256) {
        return 1;
    }

    /**
     * @notice Calculates the maximum age of the underlying oracles' responses when updating this oracle's observation.
     * @dev We use this to prevent old data from skewing our observations. Underlying oracles must update at least as
     *   frequently as this oracle does.
     * @return maxAge The maximum age of underlying oracles' responses, in seconds.
     */
    function calculateMaxAge() internal view returns (uint256) {
        if (period == 1) {
            // We don't want to subtract 1 from this and use 0 as the max age, because that would cause the oracle
            // to return data straight from the current block, which may not be secure.
            return 1;
        }

        return period - 1; // Subract 1 to ensure that we don't use any data from the previous period
    }

    function sanityCheckTvlDistributionRatio(
        uint256 price,
        uint256 tokenLiquidity,
        uint256 quoteTokenLiquidity
    ) internal view virtual returns (bool) {
        if (quoteTokenLiquidity == 0) {
            // We'll always ignore consultations where the quote token liquidity is 0
            return false;
        }

        // Calculate the ratio of token liquidity value (denominated in the quote token) to quote token liquidity
        // Safe from overflows: price and tokenLiquidity are actually uint112 in disguise
        // We multiply by 100 to avoid floating point errors => 100 represents a ratio of 1:1
        uint256 ratio = ((((price * tokenLiquidity) / _quoteTokenWholeUnit) * 100) / quoteTokenLiquidity);

        if (ratio > 1000 || ratio < 10) {
            // Reject consultations where the ratio is above 10:1 or below 1:10
            // This prevents Uniswap v3 or orderbook-like oracles from skewing our observations when liquidity is very
            // one-sided as one-sided liquidity can be used as an attack vector
            return false;
        }

        return true;
    }

    function sanityCheckQuoteTokenLiquidity(uint256 quoteTokenLiquidity) internal view virtual returns (bool) {
        return quoteTokenLiquidity >= minimumQuoteTokenLiquidity;
    }

    function sanityCheckTokenLiquidityValue(
        uint256 price,
        uint256 tokenLiquidity
    ) internal view virtual returns (bool) {
        return ((price * tokenLiquidity) / _quoteTokenWholeUnit) >= minimumTokenLiquidityValue;
    }

    function validateUnderlyingConsultation(
        uint256 price,
        uint256 tokenLiquidity,
        uint256 quoteTokenLiquidity
    ) internal view virtual returns (bool) {
        return
            sanityCheckTokenLiquidityValue(price, tokenLiquidity) &&
            sanityCheckQuoteTokenLiquidity(quoteTokenLiquidity) &&
            sanityCheckTvlDistributionRatio(price, tokenLiquidity, quoteTokenLiquidity);
    }

    function aggregateUnderlying(
        address token,
        uint256 maxAge
    ) internal view returns (ObservationLibrary.Observation memory result, uint256 validResponses) {
        ObservationLibrary.Observation[] memory observations = new ObservationLibrary.Observation[](
            oracles.length + tokenSpecificOracles[token].length
        );

        for (uint256 j = 0; j < 2; ++j) {
            OracleConfig[] memory _oracles;

            if (j == 0) _oracles = oracles;
            else _oracles = tokenSpecificOracles[token];

            for (uint256 i = 0; i < _oracles.length; ++i) {
                uint256 oPrice;
                uint256 oTokenLiquidity;
                uint256 oQuoteTokenLiquidity;

                // We don't want problematic underlying oracles to prevent us from calculating the aggregated
                // results from the other working oracles, so we use a try-catch block.
                try IOracle(_oracles[i].oracle).consult(token, maxAge) returns (
                    uint112 _price,
                    uint112 _tokenLiquidity,
                    uint112 _quoteTokenLiquidity
                ) {
                    // Promote returned data to uint256 to prevent scaling up from overflowing
                    oPrice = _price;
                    oTokenLiquidity = _tokenLiquidity;
                    oQuoteTokenLiquidity = _quoteTokenLiquidity;
                } catch Error(string memory) {
                    continue;
                } catch (bytes memory) {
                    continue;
                }

                if (oPrice <= 1 || oTokenLiquidity <= 1 || oQuoteTokenLiquidity <= 1) {
                    // Reject consultations where the price, token liquidity, or quote token liquidity is 0 or 1
                    // These values are typically reserved for errors and zero liquidity
                    continue;
                }

                // Fix differing quote token decimal places (for price)
                if (_oracles[i].quoteTokenDecimals < quoteTokenDecimals()) {
                    // Scale up
                    uint256 scalar = 10 ** (quoteTokenDecimals() - _oracles[i].quoteTokenDecimals);

                    oPrice *= scalar;
                } else if (_oracles[i].quoteTokenDecimals > quoteTokenDecimals()) {
                    // Scale down
                    uint256 scalar = 10 ** (_oracles[i].quoteTokenDecimals - quoteTokenDecimals());

                    oPrice /= scalar;
                }

                // Fix differing liquidity decimal places
                if (_oracles[i].liquidityDecimals < liquidityDecimals()) {
                    // Scale up
                    uint256 scalar = 10 ** (liquidityDecimals() - _oracles[i].liquidityDecimals);

                    oTokenLiquidity *= scalar;
                    oQuoteTokenLiquidity *= scalar;
                } else if (_oracles[i].liquidityDecimals > liquidityDecimals()) {
                    // Scale down
                    uint256 scalar = 10 ** (_oracles[i].liquidityDecimals - liquidityDecimals());

                    oTokenLiquidity /= scalar;
                    oQuoteTokenLiquidity /= scalar;
                }

                if (!validateUnderlyingConsultation(oPrice, oTokenLiquidity, oQuoteTokenLiquidity)) {
                    continue;
                }

                if (oPrice != 0 && oQuoteTokenLiquidity != 0) {
                    observations[validResponses++] = ObservationLibrary.Observation({
                        price: oPrice.toUint112(),
                        tokenLiquidity: oTokenLiquidity.toUint112(),
                        quoteTokenLiquidity: oQuoteTokenLiquidity.toUint112(),
                        timestamp: 0 // Not used
                    });
                }
            }
        }

        if (validResponses == 0) {
            return (
                ObservationLibrary.Observation({price: 0, tokenLiquidity: 0, quoteTokenLiquidity: 0, timestamp: 0}),
                0
            );
        }

        result = aggregationStrategy.aggregateObservations(observations, 0, validResponses - 1);
    }

    /// @inheritdoc AbstractOracle
    function instantFetch(
        address token
    ) internal view virtual override returns (uint112 price, uint112 tokenLiquidity, uint112 quoteTokenLiquidity) {
        (ObservationLibrary.Observation memory result, uint256 validResponses) = aggregateUnderlying(token, 0);

        // Reverts if none of the underlying oracles report anything
        require(validResponses > 0, "AggregatedOracle: INVALID_NUM_CONSULTATIONS");

        price = result.price;
        tokenLiquidity = result.tokenLiquidity;
        quoteTokenLiquidity = result.quoteTokenLiquidity;
    }
}
