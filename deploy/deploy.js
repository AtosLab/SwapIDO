const { ethers, upgrades } = require("hardhat");

async function main() {

  const [deployer] = await ethers.getSigners();

  console.log(
    "Deploying contracts with the account:",
    deployer.address
  );

  //console.log("Account balance:", (await deployer.getBalance()).toString());

  const CatDAOContract = await ethers.getContractFactory("CatDAOContract");
  const catDAO = await CatDAOContract.deploy();

  console.log("CatDAO Contract Address:", catDAO.address);
}

main()
  .then(() =>  process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });

