// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Backwards-compatible import path.
 *
 * The canonical Maple vault source now lives in `contracts/MapleVault.sol`.
 * This file remains so external users importing `MapleVaultAuthorized.sol` do not break.
 */

import { MapleVault } from "./contracts/MapleVault.sol";