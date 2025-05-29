// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "../../lib/v4-periphery/src/utils/BaseHook.sol";
import {RebaseTokenHook} from "../../src/RebaseTokenHook.sol";
import {IPoolManager} from "../../lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "../../lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";

contract RebaseTokenHookImplementation is RebaseTokenHook {
    constructor(IPoolManager _poolManager, RebaseTokenHook addressToEtch) 
        RebaseTokenHook(_poolManager, address(0), address(0)) 
    {
        Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
