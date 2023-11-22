const { BigNumber } = require("ethers");
const hre = require("hardhat");

const ethers = hre.ethers;

const cometUSDC = "0xc3d688B66703497DAA19211EEdff47f25384cdc3"; // USDC market on mainnet
const cometWETH = "0xA17581A9E3356d9A858b789D68B4d866e593aE94"; // WETH market on mainnet

const wethAddress = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2";
const usdcAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function createContract(name, ...deploymentArgs) {
    const contractFactory = await ethers.getContractFactory(name);

    const contract = await contractFactory.deploy(...deploymentArgs);

    await contract.deployed();

    return contract;
}

async function currentBlockTimestamp() {
    const currentBlockNumber = await ethers.provider.getBlockNumber();

    return await blockTimestamp(currentBlockNumber);
}

async function blockTimestamp(blockNum) {
    return (await ethers.provider.getBlock(blockNum)).timestamp;
}

async function createOracle(averagingStrategy, comet, quoteToken, period, granularity, liquidityDecimals) {
    const updateTheshold = 2000000; // 2% change -> update
    const minUpdateDelay = 5; // At least 5 seconds between every update
    const maxUpdateDelay = 60; // At most (optimistically) 60 seconds between every update

    const priceAccumulator = await createContract("StaticPriceAccumulator", quoteToken, 2);

    const liquidityAccumulator = await createContract(
        "CometSBAccumulator",
        averagingStrategy,
        comet,
        liquidityDecimals,
        updateTheshold,
        minUpdateDelay,
        maxUpdateDelay
    );

    const oracle = await createContract(
        "PeriodicAccumulationOracle",
        liquidityAccumulator.address,
        priceAccumulator.address,
        quoteToken,
        period,
        granularity
    );

    return {
        liquidityAccumulator: liquidityAccumulator,
        priceAccumulator: priceAccumulator,
        oracle: oracle,
    };
}

async function main() {
    // Periodic oracle parameters
    const period = 10; // 10 seconds
    const granularity = 1;

    // Accumulator parameters
    const averagingStrategy = await createContract("GeometricAveraging");
    const comet = cometWETH;
    const quoteToken = ethers.constants.AddressZero;
    const token = wethAddress;
    const liquidityDecimals = 4;

    const oracle = await createOracle(
        averagingStrategy.address,
        comet,
        quoteToken,
        period,
        granularity,
        liquidityDecimals
    );

    const tokenContract = await ethers.getContractAt("ERC20", token);

    const tokenSymbol = await tokenContract.symbol();

    const updateData = ethers.utils.defaultAbiCoder.encode(["address"], [token]);

    while (true) {
        try {
            if (await oracle.priceAccumulator.canUpdate(updateData)) {
                const price = await oracle.priceAccumulator["consultPrice(address,uint256)"](token, 0);
                const currentTime = await currentBlockTimestamp();

                const paUpdateData = ethers.utils.defaultAbiCoder.encode(
                    ["address", "uint", "uint"],
                    [token, price, currentTime]
                );

                const updateTx = await oracle.priceAccumulator.update(paUpdateData);
                const updateReceipt = await updateTx.wait();

                console.log(
                    "\u001b[" +
                        93 +
                        "m" +
                        "Price accumulator updated. Gas used = " +
                        updateReceipt["gasUsed"] +
                        "\u001b[0m"
                );
            }

            if (await oracle.liquidityAccumulator.canUpdate(updateData)) {
                const liquidity = await oracle.liquidityAccumulator["consultLiquidity(address,uint256)"](token, 0);
                const currentTime = await currentBlockTimestamp();

                console.log(liquidity);

                const laUpdateData = ethers.utils.defaultAbiCoder.encode(
                    ["address", "uint", "uint", "uint"],
                    [token, liquidity.tokenLiquidity, liquidity.quoteTokenLiquidity, currentTime]
                );

                const updateTx = await oracle.liquidityAccumulator.update(laUpdateData);
                const updateReceipt = await updateTx.wait();

                console.log(
                    "\u001b[" +
                        93 +
                        "m" +
                        "Liquidity accumulator updated. Gas used = " +
                        updateReceipt["gasUsed"] +
                        "\u001b[0m"
                );
            }

            if (await oracle.oracle.canUpdate(updateData)) {
                const updateTx = await oracle.oracle.update(updateData);
                const updateReceipt = await updateTx.wait();

                console.log(
                    "\u001b[" + 93 + "m" + "Oracle updated. Gas used = " + updateReceipt["gasUsed"] + "\u001b[0m"
                );
            }

            const consultation = await oracle.oracle["consult(address)"](token);

            const tokenLiquidityStr = ethers.utils.commify(
                ethers.utils.formatUnits(consultation["tokenLiquidity"], liquidityDecimals)
            );

            const quoteTokenLiquidityStr = ethers.utils.commify(
                ethers.utils.formatUnits(consultation["quoteTokenLiquidity"], liquidityDecimals)
            );

            console.log(
                "\u001b[" + 31 + "m" + "Borrow(%s) = %s, Supply(%s) = %s" + "\u001b[0m",
                tokenSymbol,
                tokenLiquidityStr,
                tokenSymbol,
                quoteTokenLiquidityStr
            );
        } catch (e) {
            console.log(e);
        }

        await sleep(1000);

        // Keep mining blocks so that block.timestamp updates
        await hre.network.provider.send("evm_mine");
    }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
