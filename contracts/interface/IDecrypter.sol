// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IDecrypter {
    function decrypt(uint8[] memory c, uint8[] memory skbytes) external returns (uint8[] memory);
}