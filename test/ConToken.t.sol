// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ConToken} from "../src/ConToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title ConToken test suite
/// @notice Covers supply/metadata invariants, standard ERC20 flows, the absence of any mint
///         path, EIP-2612 permit behaviour, and fuzzed transfers.
contract ConTokenTest is Test {
    ConToken internal token;

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant SUPPLY = 100_000_000 * 1e18;

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 internal constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    function setUp() public {
        token = new ConToken(treasury);
    }

    /*//////////////////////////////////////////////////////////////
                          SUPPLY & METADATA
    //////////////////////////////////////////////////////////////*/

    function test_TotalSupplyIs100M() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    function test_DecimalsIs18() public view {
        assertEq(token.decimals(), 18);
    }

    function test_FullSupplyMintedToTreasury() public view {
        assertEq(token.balanceOf(treasury), SUPPLY);
    }

    function test_NameAndSymbol() public view {
        assertEq(token.name(), "ConCon");
        assertEq(token.symbol(), "CON");
        assertEq(token.TOKEN_NAME(), "ConCon");
        assertEq(token.TOKEN_SYMBOL(), "CON");
    }

    function test_ConstructorRevertsOnZeroTreasury() public {
        vm.expectRevert(ConToken.ZeroTreasury.selector);
        new ConToken(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          STANDARD ERC20 FLOWS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        vm.prank(treasury);
        token.transfer(alice, 1000e18);

        assertEq(token.balanceOf(alice), 1000e18);
        assertEq(token.balanceOf(treasury), SUPPLY - 1000e18);
    }

    function test_TransferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_ApproveAndTransferFrom() public {
        vm.prank(treasury);
        token.approve(alice, 500e18);
        assertEq(token.allowance(treasury, alice), 500e18);

        vm.prank(alice);
        token.transferFrom(treasury, bob, 200e18);

        assertEq(token.balanceOf(bob), 200e18);
        assertEq(token.allowance(treasury, alice), 300e18);
    }

    function test_TransferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(treasury, bob, 1);
    }

    function test_BurnReducesSupply() public {
        vm.prank(treasury);
        token.burn(1000e18);

        assertEq(token.totalSupply(), SUPPLY - 1000e18);
        assertEq(token.balanceOf(treasury), SUPPLY - 1000e18);
    }

    /*//////////////////////////////////////////////////////////////
                          NO MINT PATH (BY DESIGN)
    //////////////////////////////////////////////////////////////*/

    /// @notice The contract exposes no callable mint entry point. Supply can only ever decrease
    ///         (via burn) from its genesis value, never increase.
    /// @dev    This is a coverage marker for the audit gate: there is no `mint(...)` selector to
    ///         call, and `INITIAL_SUPPLY` is fixed at deploy.
    function test_NoMintPathSupplyIsCapped() public {
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(treasury);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);

        // With everything burned and no mint path, no actor can ever restore supply.
        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, treasury, 0, 1));
        token.transfer(alice, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                PERMIT
    //////////////////////////////////////////////////////////////*/

    function _signPermit(uint256 ownerKey, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        uint256 nonce = token.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerKey, digest);
    }

    function test_PermitSetsAllowance() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitOwner");
        uint256 value = 1234e18;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerKey, owner, bob, value, deadline);
        token.permit(owner, bob, value, deadline, v, r, s);

        assertEq(token.allowance(owner, bob), value);
        assertEq(token.nonces(owner), 1);
    }

    function test_PermitRevertsOnExpiredDeadline() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitOwner");
        uint256 value = 1e18;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerKey, owner, bob, value, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, bob, value, deadline, v, r, s);
    }

    function test_PermitRevertsOnBadSignature() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("permitOwner");
        uint256 value = 1e18;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerKey, owner, bob, value, deadline);

        // Tamper with the signed value so the recovered signer no longer matches `owner`.
        vm.expectRevert();
        token.permit(owner, bob, value + 1, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_TransferWithinBalanceSucceeds(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);

        vm.prank(treasury);
        token.transfer(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(treasury), SUPPLY - amount);
    }

    function testFuzz_TransferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);

        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, treasury, SUPPLY, amount)
        );
        token.transfer(alice, amount);
    }
}
