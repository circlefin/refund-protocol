// SPDX-License-Identifier: Apache-2.0
/*
 * Copyright 2025 Circle Internet Group, Inc. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *     http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/RefundProtocol.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RefundProtocolTest is Test {
    RefundProtocol public refundProtocol;
    MockERC20 public usdc;
    uint256 public expiry = block.timestamp + 9999999;
    uint256 public receiverPrivateKey = 0x5678;
    uint256 public userPrivateKey = 0x1234;
    address public arbiter = address(0xABCD);
    address public user = vm.addr(userPrivateKey);
    address public receiver = vm.addr(receiverPrivateKey);
    address public refundTo = address(0x9ABC);
    address public refundTo2 = address(0xDEF0);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");
        refundProtocol = new RefundProtocol(arbiter, address(usdc), "Refund Protocol", "1.0");

        // Mint USDC to user and approve the protocol
        usdc.mint(user, 1000);
        usdc.mint(arbiter, 1000);
        vm.prank(user);
        usdc.approve(address(refundProtocol), 1000);
        vm.prank(arbiter);
        usdc.approve(address(refundProtocol), 1000);
    }

    function testPay() public {
        vm.startPrank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        (address to, uint256 amount,, address refundAddr,,) = refundProtocol.payments(0);
        assertEq(to, receiver);
        assertEq(amount, 100);
        assertEq(refundAddr, refundTo);
        assertEq(refundProtocol.balances(receiver), 100);
    }

    function testPayRefundToIsZeroAddress() public {
        vm.startPrank(user);
        vm.expectRevert(RefundProtocol.RefundToIsZeroAddress.selector);
        refundProtocol.pay(receiver, 100, address(0));
    }

    function testSetLockupSeconds() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 1);
        vm.stopPrank();

        assertEq(refundProtocol.lockupSeconds(receiver), 1);
    }

    function testSetLockupSecondsExceedsMax() public {
        uint256 lockupSeconds = refundProtocol.MAX_LOCKUP_SECONDS() + 1;
        vm.prank(arbiter);
        vm.expectRevert(RefundProtocol.LockupSecondsExceedsMax.selector);
        refundProtocol.setLockupSeconds(receiver, lockupSeconds);
    }

    function testSetLockupSecondsUnauthorized() public {
        vm.prank(receiver);
        vm.expectRevert(RefundProtocol.CallerNotAllowed.selector);
        refundProtocol.setLockupSeconds(receiver, 1);
    }

    function testWithdrawWithoutLockup() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;

        vm.prank(receiver);
        refundProtocol.withdraw(paymentIDs);
        vm.assertEq(refundProtocol.balances(receiver), 0);
        vm.assertEq(usdc.balanceOf(receiver), 100);
    }

    function testWithdrawWithSetLockup() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.startPrank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.stopPrank();
        vm.startPrank(receiver);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;

        vm.expectRevert(abi.encodeWithSelector(RefundProtocol.PaymentIsStillLocked.selector, 0));
        refundProtocol.withdraw(paymentIDs);

        vm.warp(block.timestamp + 3600); // Advance time to a valid timestamp
        refundProtocol.withdraw(paymentIDs);
        vm.assertEq(refundProtocol.balances(receiver), 0);
        vm.assertEq(usdc.balanceOf(receiver), 100);
    }

    function testWithdrawAfterPartialEarlyWithdrawal() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 90;
        uint256 feeAmount = 0;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.prank(arbiter);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);

        vm.assertEq(refundProtocol.balances(receiver), 10);
        vm.assertEq(usdc.balanceOf(receiver), 90);

        vm.warp(block.timestamp + 3600); // Advance time to a valid timestamp
        vm.prank(receiver);
        refundProtocol.withdraw(paymentIDs);
        vm.assertEq(refundProtocol.balances(receiver), 0);
        vm.assertEq(usdc.balanceOf(receiver), 100);
    }

    function testWithdrawAfterRefund() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(receiver);
        refundProtocol.refundByRecipient(0);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;

        vm.warp(block.timestamp + 3600); // Advance time to a valid timestamp
        vm.prank(receiver);
        vm.expectRevert(abi.encodeWithSelector(RefundProtocol.PaymentRefunded.selector, 0));
        refundProtocol.withdraw(paymentIDs);
    }

    function testWithdrawInsufficientFunds() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 100;
        uint256 feeAmount = 0;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.startPrank(arbiter);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);
        refundProtocol.depositArbiterFunds(100);
        refundProtocol.refundByArbiter(0);
        vm.stopPrank();

        vm.assertEq(refundProtocol.debts(receiver), 100);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.assertEq(refundProtocol.debts(receiver), 100);
        vm.assertEq(refundProtocol.balances(receiver), 100);

        uint256[] memory withdrawPaymentIDs = new uint256[](1);
        withdrawPaymentIDs[0] = 1;

        vm.warp(block.timestamp + 3600); // Advance time to a valid timestamp
        vm.prank(receiver);
        vm.expectRevert(RefundProtocol.InsufficientFunds.selector);
        refundProtocol.withdraw(withdrawPaymentIDs);
    }

    function testUnauthorizedWithdraw() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;

        vm.prank(address(user)); // Unauthorized user
        vm.expectRevert(RefundProtocol.CallerNotAllowed.selector);
        refundProtocol.withdraw(paymentIDs);
    }

    function testDepositArbiterFunds() public {
        assertEq(refundProtocol.balances(arbiter), 0);
        assertEq(usdc.balanceOf(address(refundProtocol)), 0);

        vm.startPrank(arbiter);
        refundProtocol.depositArbiterFunds(100);
        vm.stopPrank();

        assertEq(refundProtocol.balances(arbiter), 100);
        assertEq(usdc.balanceOf(address(refundProtocol)), 100);
    }

    function testDepositArbiterFundsUnauthorized() public {
        vm.startPrank(user);
        vm.expectRevert(RefundProtocol.CallerNotAllowed.selector);
        refundProtocol.depositArbiterFunds(100);
        vm.stopPrank();
    }

    function testWithdrawArbiterFunds() public {
        assertEq(refundProtocol.balances(arbiter), 0);
        assertEq(usdc.balanceOf(address(refundProtocol)), 0);

        vm.startPrank(arbiter);
        refundProtocol.depositArbiterFunds(100);
        vm.stopPrank();

        assertEq(refundProtocol.balances(arbiter), 100);
        assertEq(usdc.balanceOf(address(refundProtocol)), 100);

        vm.startPrank(arbiter);
        refundProtocol.withdrawArbiterFunds(10);

        assertEq(refundProtocol.balances(arbiter), 90);
        assertEq(usdc.balanceOf(address(refundProtocol)), 90);
        assertEq(usdc.balanceOf(arbiter), 910);
    }

    function testWithdrawArbiterFundsUnauthorized() public {
        vm.startPrank(user);
        vm.expectRevert(RefundProtocol.CallerNotAllowed.selector);
        refundProtocol.withdrawArbiterFunds(100);
        vm.stopPrank();
    }

    function testEarlyWithdrawByArbiter() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;

        vm.prank(receiver);
        vm.expectRevert(abi.encodeWithSelector(RefundProtocol.PaymentIsStillLocked.selector, 0));
        refundProtocol.withdraw(paymentIDs);

        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 90;
        uint256 feeAmount = 1;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.prank(arbiter);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);

        assertEq(refundProtocol.balances(receiver), 10);
        assertEq(refundProtocol.balances(arbiter), 1);
        assertEq(usdc.balanceOf(receiver), 89);
        assertEq(usdc.balanceOf(address(refundProtocol)), 11);
    }

    function testEarlyWithdrawByArbiterInsufficientFunds() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs1 = new uint256[](1);
        paymentIDs1[0] = 0;
        uint256[] memory withdrawalAmounts1 = new uint256[](1);
        withdrawalAmounts1[0] = 100;
        uint256 feeAmount1 = 0;

        (uint8 v1, bytes32 r1, bytes32 s1) = _generateEarlyWithdrawalSignature(
            paymentIDs1, withdrawalAmounts1, feeAmount1, expiry, 0, receiverPrivateKey
        );

        vm.startPrank(arbiter);
        refundProtocol.earlyWithdrawByArbiter(
            paymentIDs1, withdrawalAmounts1, feeAmount1, expiry, 0, receiver, v1, r1, s1
        );
        refundProtocol.depositArbiterFunds(100);
        refundProtocol.refundByArbiter(0);
        vm.stopPrank();

        vm.assertEq(refundProtocol.debts(receiver), 100);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(arbiter);
        refundProtocol.settleDebt(receiver);

        vm.assertEq(refundProtocol.debts(receiver), 0);
        vm.assertEq(refundProtocol.balances(receiver), 0);

        uint256[] memory paymentIDs2 = new uint256[](1);
        paymentIDs2[0] = 1;
        uint256[] memory withdrawalAmounts2 = new uint256[](1);
        withdrawalAmounts2[0] = 100;
        uint256 feeAmount2 = 0;

        (uint8 v2, bytes32 r2, bytes32 s2) = _generateEarlyWithdrawalSignature(
            paymentIDs2, withdrawalAmounts2, feeAmount2, expiry, 0, receiverPrivateKey
        );

        vm.prank(arbiter);
        vm.expectRevert(RefundProtocol.InsufficientFunds.selector);
        refundProtocol.earlyWithdrawByArbiter(
            paymentIDs2, withdrawalAmounts2, feeAmount2, expiry, 0, receiver, v2, r2, s2
        );
    }

    function testEarlyWithdrawByArbiterInvalidWithdrawalAmount() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 110;
        uint256 feeAmount = 0;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(RefundProtocol.InvalidWithdrawalAmount.selector, 0, 110));
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);
    }

    function testEarlyWithdrawByArbiterInvalidFeeAmount() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 100;
        uint256 feeAmount = 101;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.prank(arbiter);
        vm.expectRevert(RefundProtocol.InvalidFeeAmount.selector);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);
    }

    function testEarlyWithdrawByArbiterInvalidSignature() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 100;
        uint256 feeAmount = 100;

        uint256 agreedToFeeAmount = 1;

        (uint8 v, bytes32 r, bytes32 s) = _generateEarlyWithdrawalSignature(
            paymentIDs, withdrawalAmounts, agreedToFeeAmount, expiry, 0, receiverPrivateKey
        );

        vm.prank(arbiter);
        vm.expectRevert(RefundProtocol.InvalidSignature.selector);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);
    }

    function testEarlyWithdrawByArbiterWithdrawalHashAlreadyUsed() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 10;
        uint256 feeAmount = 2;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.prank(arbiter);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);

        vm.prank(arbiter);
        vm.expectRevert(RefundProtocol.WithdrawalHashAlreadyUsed.selector);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);
    }

    function testEarlyWithdrawByArbiterAfterRefund() public {
        vm.prank(arbiter);
        refundProtocol.setLockupSeconds(receiver, 3600);

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(receiver);
        refundProtocol.refundByRecipient(0);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 100;
        uint256 feeAmount = 0;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(RefundProtocol.PaymentRefunded.selector, 0));
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);
    }

    function testEarlyWithdrawByArbiterExpired() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 100;
        uint256 feeAmount = 0;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.warp(expiry + 1);

        vm.prank(arbiter);
        vm.expectRevert(RefundProtocol.WithdrawalHashExpired.selector);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);
    }

    function testEarlyWithdrawByArbiterPaymentDoesNotBelongToRecipient() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 100;
        uint256 feeAmount = 0;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, userPrivateKey);

        vm.prank(arbiter);
        vm.expectRevert(RefundProtocol.PaymentDoesNotBelongToRecipient.selector);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, user, v, r, s);
    }

    function testEarlyWithdrawByArbiterMismatchedArrays() public {
        uint256[] memory paymentIDs = new uint256[](2);
        paymentIDs[0] = 0;
        paymentIDs[0] = 1;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 100;
        uint256 feeAmount = 0;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.prank(arbiter);
        vm.expectRevert(RefundProtocol.MismatchedEarlyWithdrawalArrays.selector);
        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);
    }

    function testEarlyWithdrawByArbiterUnauthorized() public {
        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;
        uint256[] memory withdrawalAmounts = new uint256[](1);
        withdrawalAmounts[0] = 100;
        uint256 feeAmount = 0;

        (uint8 v, bytes32 r, bytes32 s) =
            _generateEarlyWithdrawalSignature(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiverPrivateKey);

        vm.prank(user);
        vm.expectRevert(RefundProtocol.CallerNotAllowed.selector);

        refundProtocol.earlyWithdrawByArbiter(paymentIDs, withdrawalAmounts, feeAmount, expiry, 0, receiver, v, r, s);
    }

    function testUpdateRefundTo() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(refundTo);
        refundProtocol.updateRefundTo(0, refundTo2);

        (,,, address refundAddr,,) = refundProtocol.payments(0);
        assertEq(refundAddr, refundTo2);
    }

    function testUpdateRefundToZeroAddress() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(refundTo);
        vm.expectRevert(RefundProtocol.RefundToIsZeroAddress.selector);
        refundProtocol.updateRefundTo(0, address(0));
    }

    function testUpdateRefundToUnauthorized() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(receiver);
        vm.expectRevert(RefundProtocol.CallerNotAllowed.selector);
        refundProtocol.updateRefundTo(0, receiver);
    }

    function testRefundByRecipient() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(receiver);
        refundProtocol.refundByRecipient(0);

        assertEq(usdc.balanceOf(refundTo), 100);
        assertEq(usdc.balanceOf(address(refundProtocol)), 0);
        assertEq(refundProtocol.balances(receiver), 0);
    }

    function testRefundByRecipientUnauthorized() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(user);
        vm.expectRevert(RefundProtocol.CallerNotAllowed.selector);
        refundProtocol.refundByRecipient(0);
    }

    function testRefundByArbiter() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(arbiter);
        refundProtocol.refundByArbiter(0);

        assertEq(usdc.balanceOf(refundTo), 100);
        assertEq(usdc.balanceOf(address(refundProtocol)), 0);
        assertEq(refundProtocol.balances(receiver), 0);
    }

    function testRefundByArbiterWhenArbiterFundsAreUsed() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;

        vm.prank(receiver);
        refundProtocol.withdraw(paymentIDs);

        vm.startPrank(arbiter);
        refundProtocol.depositArbiterFunds(100);

        refundProtocol.refundByArbiter(0);

        assertEq(usdc.balanceOf(refundTo), 100);
        assertEq(usdc.balanceOf(address(refundProtocol)), 0);
        assertEq(refundProtocol.balances(receiver), 0);
        assertEq(refundProtocol.balances(arbiter), 0);
        assertEq(refundProtocol.debts(receiver), 100);
    }

    function testRefundByArbiterUnauthorized() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        vm.prank(user);
        vm.expectRevert(RefundProtocol.CallerNotAllowed.selector);
        refundProtocol.refundByArbiter(0);
    }

    function testSettleDebt() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;

        vm.prank(receiver);
        refundProtocol.withdraw(paymentIDs);

        vm.startPrank(arbiter);
        refundProtocol.depositArbiterFunds(100);

        refundProtocol.refundByArbiter(0);
        vm.stopPrank();

        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);
        vm.startPrank(arbiter);
        refundProtocol.settleDebt(receiver);

        assertEq(usdc.balanceOf(address(refundProtocol)), 100);
        assertEq(refundProtocol.balances(receiver), 0);
        assertEq(refundProtocol.balances(arbiter), 100);
        assertEq(refundProtocol.debts(receiver), 0);
    }

    function testSettleDebtPartially() public {
        vm.prank(user);
        refundProtocol.pay(receiver, 100, refundTo);

        uint256[] memory paymentIDs = new uint256[](1);
        paymentIDs[0] = 0;

        vm.prank(receiver);
        refundProtocol.withdraw(paymentIDs);

        vm.startPrank(arbiter);
        refundProtocol.depositArbiterFunds(100);

        refundProtocol.refundByArbiter(0);
        vm.stopPrank();

        vm.prank(user);
        refundProtocol.pay(receiver, 50, refundTo);
        vm.startPrank(arbiter);
        refundProtocol.settleDebt(receiver);

        assertEq(usdc.balanceOf(address(refundProtocol)), 50);
        assertEq(refundProtocol.balances(receiver), 0);
        assertEq(refundProtocol.balances(arbiter), 50);
        assertEq(refundProtocol.debts(receiver), 50);
    }

    function _generateEarlyWithdrawalSignature(
        uint256[] memory paymentIDs,
        uint256[] memory withdrawalAmounts,
        uint256 feeAmount,
        uint256 _expiry,
        uint256 salt,
        uint256 signerPrivateKey
    ) public view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 withdrawalInfoHash =
            refundProtocol.hashEarlyWithdrawalInfo(paymentIDs, withdrawalAmounts, feeAmount, _expiry, salt);
        (v, r, s) = vm.sign(signerPrivateKey, withdrawalInfoHash);
    }
}
