import chai, { expect } from 'chai'
import { solidity } from 'ethereum-waffle'

import { deployERC20, deployFactory, expandTo18Decimals, getPair } from './utils/helper'
import { Constants } from './utils/constants'
import { Fixtures } from './utils/fixtures'

const hre = require("hardhat");
chai.use(solidity)

describe('SyncSwapFactory', () => {

    before(async () => {
        const accounts = await hre.ethers.getSigners();
        Fixtures.set('factory', await deployFactory(accounts[0].address));

        const tokenA = await deployERC20('Test Token A', 'TESTA', 18, expandTo18Decimals(10000));
        const tokenB = await deployERC20('Test Token B', 'TESTB', 18, expandTo18Decimals(10000));
        const [token0, token1] = Number(tokenA.address) < Number(tokenB.address) ? [tokenA, tokenB] : [tokenB, tokenA];
        Fixtures.set('token0', token0);
        Fixtures.set('token1', token1);
    });

    it('feeTo, feeToSetter, allPairsLength', async () => {
        const factory = Fixtures.use('factory');
        expect(await factory.feeTo()).to.eq(Constants.ZERO_ADDRESS);
        const accounts = await hre.ethers.getSigners();
        expect(await factory.feeToSetter()).to.eq(accounts[0].address);
        expect(await factory.allPairsLength()).to.eq(0);
    });

    it('createPair', async () => {
        const token0 = Fixtures.use('token0').address;
        const token1 = Fixtures.use('token1').address;
        const factory = Fixtures.use('factory');

        await expect(factory.createPair(token0, token0))
            .to.be.revertedWith('IDENTICAL_ADDRESSES');

        await expect(factory.createPair(Constants.ZERO_ADDRESS, token1))
            .to.be.revertedWith('ZERO_ADDRESS');

        const tx = await factory.createPair(token0, token1);
        expect(tx).to.emit(factory, 'PairCreated');

        const receipt = await tx.wait();
        //expect(receipt.gasUsed).to.eq(2684348); // 2512920 for Uniswap V2

        await expect(factory.createPair(token0, token1))
            .to.be.revertedWith('PAIR_EXISTS');

        await expect(factory.createPair(token1, token0)) // reverse
            .to.be.revertedWith('PAIR_EXISTS');

        Fixtures.set('pair', await getPair(factory, token0, token1));
    });

    it('After createPair', async () => {
        const token0 = Fixtures.use('token0').address;
        const token1 = Fixtures.use('token1').address;
        const factory = Fixtures.use('factory');
        const pair = Fixtures.use('pair');

        expect(await factory.getPair(token0, token1)).to.eq(pair.address);
        expect(await factory.getPair(token1, token0)).to.eq(pair.address); // reverse

        expect(await factory.allPairs(0)).to.eq(pair.address);
        expect(await factory.allPairsLength()).to.eq(1);

        expect(await pair.factory()).to.eq(factory.address);
        expect(await pair.token0()).to.eq(token0);
        expect(await pair.token1()).to.eq(token1);
    });

    it('Pair metadata (name, symbol and decimals)', async () => {
        const symbol0 = await Fixtures.use('token0').symbol();
        const symbol1 = await Fixtures.use('token1').symbol();
        const pair = Fixtures.use('pair');

        expect(await pair.name()).to.eq(`SyncSwap ${symbol0}/${symbol1} LP Token`);
        expect(await pair.symbol()).to.eq(`${symbol0}/${symbol1} SLP`);
        expect(await pair.decimals()).to.eq(18);
    });

    it('setFeeTo', async () => {
        const factory = Fixtures.use('factory');

        const accounts = await hre.ethers.getSigners();
        // Set `feeTo` with account 1
        await expect(factory.connect(accounts[1]).setFeeTo(accounts[1].address)).to.be.revertedWith('FORBIDDEN');

        // Set `feeTo` from account 0 to 1
        await factory.setFeeTo(accounts[1].address);
        expect(await factory.feeTo()).to.eq(accounts[1].address);
    });

    it('setFeeToSetter', async () => {
        const factory = Fixtures.use('factory');

        const accounts = await hre.ethers.getSigners();
        // Set `feeToSetter` with account 1
        await expect(factory.connect(accounts[1]).setFeeToSetter(accounts[1].address)).to.be.revertedWith('FORBIDDEN');

        // Set `feeToSetter` from account 0 to 1 (pending)
        await factory.setFeeToSetter(accounts[1].address);
        expect(await factory.pendingFeeToSetter()).to.eq(accounts[1].address);
    });

    it('acceptFeeToSetter', async () => {
        const factory = Fixtures.use('factory');

        const accounts = await hre.ethers.getSigners();
        // Accept `feeToSetter` for account 1
        await factory.connect(accounts[1]).acceptFeeToSetter();
        expect(await factory.feeToSetter()).to.eq(accounts[1].address);

        // Set `feeToSetter` with account 0
        await expect(factory.setFeeToSetter(accounts[0].address)).to.be.revertedWith('FORBIDDEN');
    });
});