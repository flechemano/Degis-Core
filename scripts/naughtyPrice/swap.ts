import { formatUnits } from "ethers/lib/utils";
import hre from "hardhat";
import { getLatestBlockTimestamp, stablecoinToWei } from "../../test/utils";
import {
  MockUSD,
  MockUSD__factory,
  NaughtyFactory,
  NaughtyFactory__factory,
  NaughtyPair,
  NaughtyPair__factory,
  NaughtyRouter,
  NaughtyRouter__factory,
  PolicyCore,
  PolicyCore__factory,
} from "../../typechain";
import { readAddressList } from "../contractAddress";

async function main() {
  const addressList = readAddressList();

  const { getNamedAccounts, network } = hre;
  console.log("You are adding new pools at the ", network.name, " network");

  const routerAddress = addressList[network.name].NaughtyRouter;
  const coreAddress = addressList[network.name].PolicyCore;
  const usdAddress = addressList[network.name].MockUSD;
  const factoryAddress = addressList[network.name].NaughtyFactory;

  console.log("The farming pool address of this network is: ", routerAddress);

  // Named accounts
  const { deployer } = await getNamedAccounts();
  console.log("The dev account is: ", deployer);

  // Signers
  const [dev_account] = await hre.ethers.getSigners();
  console.log("The dfault signer is: ", dev_account.address);

  // Get the contract factory and instance
  const NaughtyRouter: NaughtyRouter__factory =
    await hre.ethers.getContractFactory("NaughtyRouter");
  const router: NaughtyRouter = NaughtyRouter.attach(routerAddress);

  const PolicyCore: PolicyCore__factory = await hre.ethers.getContractFactory(
    "PolicyCore"
  );
  const core: PolicyCore = PolicyCore.attach(coreAddress);

  const NaughtyFactory: NaughtyFactory__factory =
    await hre.ethers.getContractFactory("NaughtyFactory");
  const factory: NaughtyFactory = NaughtyFactory.attach(factoryAddress);

  const policyTokenName = "AVAX_100.0_L_0322";

  const policyTokenInfo = await core.policyTokenInfoMapping(policyTokenName);

  const pairAddress = await factory.getPairAddress(
    policyTokenInfo.policyTokenAddress,
    usdAddress
  );

  const NaughtyPair: NaughtyPair__factory = await hre.ethers.getContractFactory(
    "NaughtyPair"
  );
  const pair: NaughtyPair = NaughtyPair.attach(pairAddress);

  const now = await getLatestBlockTimestamp(ethers.provider);

  const MockUSD: MockUSD__factory = await hre.ethers.getContractFactory(
    "MockUSD"
  );
  const usd: MockUSD = MockUSD.attach(usdAddress);

  await usd.approve(core.address, stablecoinToWei("100"));
  await core.deposit(policyTokenName, usdAddress, stablecoinToWei("100"));

  const NPPolicyToken = new ethers.Contract(
    policyTokenInfo.policyTokenAddress,
    ["function approve(address,uint256)"],
    dev_account
  );
  await NPPolicyToken.approve(router.address, stablecoinToWei("100"));

  const usd_balance_b = await usd.balanceOf(dev_account.address);
  //Address to add
  const tx = await router.swapExactTokensforTokens(
    stablecoinToWei("20"),
    stablecoinToWei("2"),
    policyTokenInfo.policyTokenAddress,
    usdAddress,
    dev_account.address,
    now + 3000
  );
  console.log("tx details:", await tx.wait());

  const usd_balance_a = await usd.balanceOf(dev_account.address);

  console.log("usd get Balance before: ", formatUnits(usd_balance_b, 6));
  console.log("usd get Balance after: ", formatUnits(usd_balance_a, 6));
}

main()
  .then(() => {
    process.exitCode = 0;
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
