import chai, { expect } from 'chai'
import { solidity } from 'ethereum-waffle'

import { createPair, deployERC20, deployFactory, deployFeeReceiver, encodePrice, expandTo18Decimals, getPair, mineBlock, mineBlockAfter } from './utils/helper'
import { Constants } from './utils/constants'
import { Fixtures } from './utils/fixtures'
import { BigNumber } from 'ethers'

const hre = require("hardhat");
chai.use(solidity)

const MINIMUM_LIQUIDITY = BigNumber.from(1000);

describe('SyncSwapPair', () => {

    // Reset pair before each test
    beforeEach(async () => {
        const tokenA = await deployERC20('Test Token A', 'TESTA', 18, expandTo18Decimals(10000));
        const tokenB = await deployERC20('Test Token B', 'TESTB', 18, expandTo18Decimals(10000));
        const [token0, token1] = Number(tokenA.address) < Number(tokenB.address) ? [tokenA, tokenB] : [tokenB, tokenA];
        Fixtures.set('token0', token0);
        Fixtures.set('token1', token1);

        const accounts = await hre.ethers.getSigners();
        const factory = Fixtures.set('factory', await deployFactory(accounts[0].address));

        const feeReceiver = Fixtures.set('feeReceiver', await deployFeeReceiver(factory.address, tokenA.address));
        await factory.setFeeTo(feeReceiver.address);

        Fixtures.set('pair', await createPair(factory, token0.address, token1.address));
    });

    it('mint', async () => {
        const token0 = Fixtures.use('token0');
        const token1 = Fixtures.use('token1');
        const pair = Fixtures.use('pair');

        const token0Amount = expandTo18Decimals(1);
        const token1Amount = expandTo18Decimals(4);
        await token0.transfer(pair.address, token0Amount);
        await token1.transfer(pair.address, token1Amount);

        const accounts = await hre.ethers.getSigners();
        const expectedLiquidity = expandTo18Decimals(2);
        await expect(pair.mint(accounts[0].address))
            .to.emit(pair, 'Transfer')
            .withArgs(Constants.ZERO_ADDRESS, Constants.ZERO_ADDRESS, MINIMUM_LIQUIDITY)
            .to.emit(pair, 'Transfer')
            .withArgs(Constants.ZERO_ADDRESS, accounts[0].address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount, token1Amount)
            .to.emit(pair, 'Mint')
            .withArgs(accounts[0].address, token0Amount, token1Amount);

        expect(await pair.totalSupply()).to.eq(expectedLiquidity);
        expect(await pair.balanceOf(accounts[0].address)).to.eq(expectedLiquidity.sub(MINIMUM_LIQUIDITY));
        expect(await token0.balanceOf(pair.address)).to.eq(token0Amount);
        expect(await token1.balanceOf(pair.address)).to.eq(token1Amount);

        const reserves = await pair.getReserves();
        expect(reserves[0]).to.eq(token0Amount);
        expect(reserves[1]).to.eq(token1Amount);
    });

    async function addLiquidity(token0Amount: BigNumber, token1Amount: BigNumber) {
        const token0 = Fixtures.use('token0');
        const token1 = Fixtures.use('token1');
        const pair = Fixtures.use('pair');
        const accounts = await hre.ethers.getSigners();

        await token0.transfer(pair.address, token0Amount)
        await token1.transfer(pair.address, token1Amount)
        await pair.mint(accounts[0].address);
    }

    const swapTestCases: BigNumber[][] = [
        [1, 5, 10, '1662497915624478906'],
        [1, 10, 5, '453305446940074565'],

        [2, 5, 10, '2851015155847869602'],
        [2, 10, 5, '831248957812239453'],

        [1, 10, 10, '906610893880149131'],
        [1, 100, 100, '987158034397061298'],
        [1, 1000, 1000, '996006981039903216']
    ].map(a => a.map(n => (typeof n === 'string' ? BigNumber.from(n) : expandTo18Decimals(n))))

    swapTestCases.forEach((swapTestCase, i) => {
        it(`getInputPrice:${i}`, async () => {
            const token0 = Fixtures.use('token0');
            const pair = Fixtures.use('pair');
            const accounts = await hre.ethers.getSigners();

            const [swapAmount, token0Amount, token1Amount, expectedOutputAmount] = swapTestCase;
            await addLiquidity(token0Amount, token1Amount);
            await token0.transfer(pair.address, swapAmount);
            await expect(pair.swap(0, expectedOutputAmount.add(1), accounts[0].address, '0x')).to.be.revertedWith(
                'K'
            );
            await pair.swap(0, expectedOutputAmount, accounts[0].address, '0x');
        });

        it(`getInputPrice:single:${i}`, async () => {
            const token0 = Fixtures.use('token0');
            const pair = Fixtures.use('pair');
            const accounts = await hre.ethers.getSigners();

            const [swapAmount, token0Amount, token1Amount, expectedOutputAmount] = swapTestCase;
            await addLiquidity(token0Amount, token1Amount);
            await token0.transfer(pair.address, swapAmount);
            await expect(pair.swapFor1(expectedOutputAmount.add(1), accounts[0].address)).to.be.revertedWith(
                'K'
            );
            await pair.swapFor1(expectedOutputAmount, accounts[0].address);
        });
    })

    const swapTestCasesCustomFee: BigNumber[][] = [
        [1, 5, 10, '1663192997082117548'],
        [1, 10, 5, '453512161854967037'],

        [2, 5, 10, '2852037169406719085'],
        [2, 10, 5, '831596498541058774'],

        [1, 10, 10, '907024323709934075'],
        [1, 100, 100, '987648209114086982'],
        [1, 1000, 1000, '996505985279683515']
    ].map(a => a.map(n => (typeof n === 'string' ? BigNumber.from(n) : expandTo18Decimals(n))))

    swapTestCasesCustomFee.forEach((swapTestCase, i) => {
        it(`getInputPrice:customFee:${i}`, async () => {
            const token0 = Fixtures.use('token0');
            const pair = Fixtures.use('pair');
            const accounts = await hre.ethers.getSigners();

            const factory = Fixtures.use('factory');
            await factory.setSwapFeeOverride(pair.address, 25);

            const [swapAmount, token0Amount, token1Amount, expectedOutputAmount] = swapTestCase;
            await addLiquidity(token0Amount, token1Amount);
            await token0.transfer(pair.address, swapAmount);
            await expect(pair.swap(0, expectedOutputAmount.add(1), accounts[0].address, '0x')).to.be.revertedWith(
                'K'
            );
            await pair.swap(0, expectedOutputAmount, accounts[0].address, '0x');
        });

        it(`getInputPrice:customFee:single:${i}`, async () => {
            const token0 = Fixtures.use('token0');
            const pair = Fixtures.use('pair');
            const accounts = await hre.ethers.getSigners();

            const factory = Fixtures.use('factory');
            await factory.setSwapFee(25);

            const [swapAmount, token0Amount, token1Amount, expectedOutputAmount] = swapTestCase;
            await addLiquidity(token0Amount, token1Amount);
            await token0.transfer(pair.address, swapAmount);
            await expect(pair.swapFor1(expectedOutputAmount.add(1), accounts[0].address)).to.be.revertedWith(
                'K'
            );
            await pair.swapFor1(expectedOutputAmount, accounts[0].address);
        });
    })

    const optimisticTestCases: BigNumber[][] = [
        ['997000000000000000', 5, 10, 1], // given amountIn, amountOut = floor(amountIn * .997)
        ['997000000000000000', 10, 5, 1],
        ['997000000000000000', 5, 5, 1],
        [1, 5, 5, '1003009027081243732'] // given amountOut, amountIn = ceiling(amountOut / .997)
    ].map(a => a.map(n => (typeof n === 'string' ? BigNumber.from(n) : expandTo18Decimals(n))));

    optimisticTestCases.forEach((optimisticTestCase, i) => {
        it(`optimistic:${i}`, async () => {
            const token0 = Fixtures.use('token0');
            const pair = Fixtures.use('pair');
            const accounts = await hre.ethers.getSigners();

            const [outputAmount, token0Amount, token1Amount, inputAmount] = optimisticTestCase;
            await addLiquidity(token0Amount, token1Amount);
            await token0.transfer(pair.address, inputAmount);
            await expect(pair.swap(outputAmount.add(1), 0, accounts[0].address, '0x')).to.be.revertedWith(
                'K'
            );
            await pair.swap(outputAmount, 0, accounts[0].address, '0x');
        });
    });

    it('swap:token0', async () => {
        const token0 = Fixtures.use('token0');
        const token1 = Fixtures.use('token1');
        const pair = Fixtures.use('pair');
        const accounts = await hre.ethers.getSigners();

        const token0Amount = expandTo18Decimals(5)
        const token1Amount = expandTo18Decimals(10)
        await addLiquidity(token0Amount, token1Amount)

        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = BigNumber.from('1662497915624478906')
        await token0.transfer(pair.address, swapAmount)
        await expect(pair.swap(0, expectedOutputAmount, accounts[0].address, '0x'))
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, accounts[0].address, expectedOutputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(swapAmount), token1Amount.sub(expectedOutputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(accounts[0].address, swapAmount, 0, 0, expectedOutputAmount, accounts[0].address)

        const reserves = await pair.getReserves()
        expect(reserves[0]).to.eq(token0Amount.add(swapAmount))
        expect(reserves[1]).to.eq(token1Amount.sub(expectedOutputAmount))
        expect(await token0.balanceOf(pair.address)).to.eq(token0Amount.add(swapAmount))
        expect(await token1.balanceOf(pair.address)).to.eq(token1Amount.sub(expectedOutputAmount))
        const totalSupplyToken0 = await token0.totalSupply()
        const totalSupplyToken1 = await token1.totalSupply()
        expect(await token0.balanceOf(accounts[0].address)).to.eq(totalSupplyToken0.sub(token0Amount).sub(swapAmount))
        expect(await token1.balanceOf(accounts[0].address)).to.eq(totalSupplyToken1.sub(token1Amount).add(expectedOutputAmount))
    });

    it('swap:single:token0', async () => {
        const token0 = Fixtures.use('token0');
        const token1 = Fixtures.use('token1');
        const pair = Fixtures.use('pair');
        const accounts = await hre.ethers.getSigners();

        const token0Amount = expandTo18Decimals(5)
        const token1Amount = expandTo18Decimals(10)
        await addLiquidity(token0Amount, token1Amount)

        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = BigNumber.from('1662497915624478906')
        await token0.transfer(pair.address, swapAmount)
        await expect(pair.swapFor1(expectedOutputAmount, accounts[0].address))
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, accounts[0].address, expectedOutputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(swapAmount), token1Amount.sub(expectedOutputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(accounts[0].address, swapAmount, 0, 0, expectedOutputAmount, accounts[0].address)

        const reserves = await pair.getReserves()
        expect(reserves[0]).to.eq(token0Amount.add(swapAmount))
        expect(reserves[1]).to.eq(token1Amount.sub(expectedOutputAmount))
        expect(await token0.balanceOf(pair.address)).to.eq(token0Amount.add(swapAmount))
        expect(await token1.balanceOf(pair.address)).to.eq(token1Amount.sub(expectedOutputAmount))
        const totalSupplyToken0 = await token0.totalSupply()
        const totalSupplyToken1 = await token1.totalSupply()
        expect(await token0.balanceOf(accounts[0].address)).to.eq(totalSupplyToken0.sub(token0Amount).sub(swapAmount))
        expect(await token1.balanceOf(accounts[0].address)).to.eq(totalSupplyToken1.sub(token1Amount).add(expectedOutputAmount))
    });

    it('swap:token1', async () => {
        const token0 = Fixtures.use('token0');
        const token1 = Fixtures.use('token1');
        const pair = Fixtures.use('pair');
        const accounts = await hre.ethers.getSigners();

        const token0Amount = expandTo18Decimals(5)
        const token1Amount = expandTo18Decimals(10)
        await addLiquidity(token0Amount, token1Amount)

        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = BigNumber.from('453305446940074565')
        await token1.transfer(pair.address, swapAmount)
        await expect(pair.swap(expectedOutputAmount, 0, accounts[0].address, '0x'))
            .to.emit(token0, 'Transfer')
            .withArgs(pair.address, accounts[0].address, expectedOutputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.sub(expectedOutputAmount), token1Amount.add(swapAmount))
            .to.emit(pair, 'Swap')
            .withArgs(accounts[0].address, 0, swapAmount, expectedOutputAmount, 0, accounts[0].address)

        const reserves = await pair.getReserves()
        expect(reserves[0]).to.eq(token0Amount.sub(expectedOutputAmount))
        expect(reserves[1]).to.eq(token1Amount.add(swapAmount))
        expect(await token0.balanceOf(pair.address)).to.eq(token0Amount.sub(expectedOutputAmount))
        expect(await token1.balanceOf(pair.address)).to.eq(token1Amount.add(swapAmount))
        const totalSupplyToken0 = await token0.totalSupply()
        const totalSupplyToken1 = await token1.totalSupply()
        expect(await token0.balanceOf(accounts[0].address)).to.eq(totalSupplyToken0.sub(token0Amount).add(expectedOutputAmount))
        expect(await token1.balanceOf(accounts[0].address)).to.eq(totalSupplyToken1.sub(token1Amount).sub(swapAmount))
    })

    it('swap:single:token1', async () => {
        const token0 = Fixtures.use('token0');
        const token1 = Fixtures.use('token1');
        const pair = Fixtures.use('pair');
        const accounts = await hre.ethers.getSigners();

        const token0Amount = expandTo18Decimals(5)
        const token1Amount = expandTo18Decimals(10)
        await addLiquidity(token0Amount, token1Amount)

        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = BigNumber.from('453305446940074565')
        await token1.transfer(pair.address, swapAmount)
        await expect(pair.swapFor0(expectedOutputAmount, accounts[0].address))
            .to.emit(token0, 'Transfer')
            .withArgs(pair.address, accounts[0].address, expectedOutputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.sub(expectedOutputAmount), token1Amount.add(swapAmount))
            .to.emit(pair, 'Swap')
            .withArgs(accounts[0].address, 0, swapAmount, expectedOutputAmount, 0, accounts[0].address)

        const reserves = await pair.getReserves()
        expect(reserves[0]).to.eq(token0Amount.sub(expectedOutputAmount))
        expect(reserves[1]).to.eq(token1Amount.add(swapAmount))
        expect(await token0.balanceOf(pair.address)).to.eq(token0Amount.sub(expectedOutputAmount))
        expect(await token1.balanceOf(pair.address)).to.eq(token1Amount.add(swapAmount))
        const totalSupplyToken0 = await token0.totalSupply()
        const totalSupplyToken1 = await token1.totalSupply()
        expect(await token0.balanceOf(accounts[0].address)).to.eq(totalSupplyToken0.sub(token0Amount).add(expectedOutputAmount))
        expect(await token1.balanceOf(accounts[0].address)).to.eq(totalSupplyToken1.sub(token1Amount).sub(swapAmount))
    })

    it('swap:gas', async () => {
        const token1 = Fixtures.use('token1');
        const pair = Fixtures.use('pair');
        const accounts = await hre.ethers.getSigners();

        const token0Amount = expandTo18Decimals(5)
        const token1Amount = expandTo18Decimals(10)
        await addLiquidity(token0Amount, token1Amount)

        // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
        await mineBlock();
        await pair.sync();

        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = BigNumber.from('453305446940074565')
        await token1.transfer(pair.address, swapAmount)
        await mineBlock();

        const tx = await pair.swap(expectedOutputAmount, 0, accounts[0].address, '0x');
        const receipt = await tx.wait()

        // Gas cost are higher because of the configurable swap fee point,
        // the gas cost will be 73498 without it.
        expect(receipt.gasUsed).to.eq(83298) // 73462 for Uniswap V2
    });

    it('swap:single:gas', async () => {
        const token1 = Fixtures.use('token1');
        const pair = Fixtures.use('pair');
        const accounts = await hre.ethers.getSigners();

        const token0Amount = expandTo18Decimals(5)
        const token1Amount = expandTo18Decimals(10)
        await addLiquidity(token0Amount, token1Amount)

        // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
        await mineBlock();
        await pair.sync();

        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = BigNumber.from('453305446940074565')
        await token1.transfer(pair.address, swapAmount)
        await mineBlock();

        const tx = await pair.swapFor0(expectedOutputAmount, accounts[0].address);
        const receipt = await tx.wait()
        expect(receipt.gasUsed).to.eq(82051)
    });

    it('burn', async () => {
        const token0 = Fixtures.use('token0');
        const token1 = Fixtures.use('token1');
        const pair = Fixtures.use('pair');
        const accounts = await hre.ethers.getSigners();

        const token0Amount = expandTo18Decimals(3)
        const token1Amount = expandTo18Decimals(3)
        await addLiquidity(token0Amount, token1Amount)

        const expectedLiquidity = expandTo18Decimals(3)
        await pair.transfer(pair.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
        await expect(pair.burn(accounts[0].address))
            .to.emit(pair, 'Transfer')
            .withArgs(pair.address, Constants.ZERO_ADDRESS, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
            .to.emit(token0, 'Transfer')
            .withArgs(pair.address, accounts[0].address, token0Amount.sub(1000))
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, accounts[0].address, token1Amount.sub(1000))
            .to.emit(pair, 'Sync')
            .withArgs(1000, 1000)
            .to.emit(pair, 'Burn')
            .withArgs(accounts[0].address, token0Amount.sub(1000), token1Amount.sub(1000), accounts[0].address)

        expect(await pair.balanceOf(accounts[0].address)).to.eq(0)
        expect(await pair.totalSupply()).to.eq(MINIMUM_LIQUIDITY)
        expect(await token0.balanceOf(pair.address)).to.eq(1000)
        expect(await token1.balanceOf(pair.address)).to.eq(1000)
        const totalSupplyToken0 = await token0.totalSupply()
        const totalSupplyToken1 = await token1.totalSupply()
        expect(await token0.balanceOf(accounts[0].address)).to.eq(totalSupplyToken0.sub(1000))
        expect(await token1.balanceOf(accounts[0].address)).to.eq(totalSupplyToken1.sub(1000))
    });
});