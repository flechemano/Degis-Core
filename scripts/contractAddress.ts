/**
 * Remember to use this function in the root path of your hardhat project
 */

import * as fs from "fs";

export const readAddressList = function () {
  // const filePath = __dirname + "/address.json"
  return JSON.parse(fs.readFileSync("address.json", "utf-8"));
};

export const storeAddressList = function (addressList: object) {
  fs.writeFileSync("address.json", JSON.stringify(addressList, null, "\t"));
};
