// SPDX-License-Identifier: Apache 2
pragma solidity >=0.8.8 <0.9.0;

import "./NttManager.sol";

/// @title NttManagerWithPayload
/// @notice The NttManagerWithPayload contract is an implementation of
///         NttManager that lets callers attach a custom payload to the
///         `NativeTokenTransfer.additionalPayload` field of a transfer.
///
/// @dev    All of the developer notes from `NttManager` apply here.
///
/// @dev    The payload is covered by the manager message digest, so it is attested
///         together with the transfer. The destination NttManager does not act on it
///         (the inbound `_handleAdditionalPayload` hook is left as a no-op); it is meant
///         for relayers and contracts that parse the VAA themselves.
///
/// @dev    The destination chain's NttManager must be able to decode an additional
///         payload. EVM managers can; Solana managers built with `EmptyPayload` cannot.
///
/// @dev    The payload is handed to `_prepareNativeTokenTransfer` through a storage slot
///         that is written and cleared within `transferWithPayload` (the slot is zero
///         outside of it). `nonReentrant` prevents any other transfer from observing it.
contract NttManagerWithPayload is NttManager {
    constructor(
        address _token,
        Mode _mode,
        uint16 _chainId,
        uint64 _rateLimitDuration,
        bool _skipRateLimiting
    ) NttManager(_token, _mode, _chainId, _rateLimitDuration, _skipRateLimiting) {}

    // =============== Storage ==============================================================

    bytes32 private constant PAYLOAD_SLOT = bytes32(uint256(keccak256("ntt.payload")) - 1);

    /// @dev The transceiver message encodes the manager message behind a uint16 length, and
    ///      the manager message wraps the payload in 147 bytes of headers: 81 (NativeTokenTransfer)
    ///      + 66 (NttManagerMessage). A longer payload passes the inner encoders but not that one.
    uint256 private constant MAX_PAYLOAD_LENGTH = type(uint16).max - 147;

    struct _Payload {
        bytes data;
    }

    // =============== Storage Getters/Setters ==============================================

    function _getPayloadStorage() internal pure returns (_Payload storage $) {
        uint256 slot = uint256(PAYLOAD_SLOT);
        assembly ("memory-safe") {
            $.slot := slot
        }
    }

    // ==================== External Interface ===============================================

    /// @notice Transfer a given amount to a recipient on a given chain, attaching a custom
    ///         payload to the `NativeTokenTransfer.additionalPayload` field.
    /// @dev Payload transfers are never queued: if the outbound limit is hit, the call reverts
    ///      with `NotEnoughCapacity`, since a queued transfer would not retain the payload.
    ///      Recommended that the first 4 bytes of the payload are a unique prefix.
    /// @param amount The amount to transfer.
    /// @param recipientChain The Wormhole chain ID for the destination.
    /// @param recipient The recipient address.
    /// @param refundAddress The address to which a refund for unused gas is issued on the recipient chain.
    /// @param transceiverInstructions Additional instructions to be forwarded to the recipient chain.
    /// @param payload The custom payload (at most 65388 bytes).
    /// @return msgId The resulting message ID of the transfer
    function transferWithPayload(
        uint256 amount,
        uint16 recipientChain,
        bytes32 recipient,
        bytes32 refundAddress,
        bytes memory transceiverInstructions,
        bytes memory payload
    ) external payable nonReentrant whenNotPaused returns (uint64 msgId) {
        // fail before writing to storage; the transceiver message encoder enforces the same bound
        if (payload.length > MAX_PAYLOAD_LENGTH) {
            revert TransceiverStructs.PayloadTooLong(payload.length);
        }
        _Payload storage $ = _getPayloadStorage();
        $.data = payload;
        msgId = _transferEntryPoint(
            amount, recipientChain, recipient, refundAddress, false, transceiverInstructions
        );
        delete $.data;
    }

    // ==================== Overridden NttManager Implementations =================================

    function _prepareNativeTokenTransfer(
        TrimmedAmount amount,
        bytes32 recipient,
        uint16 recipientChain,
        uint64 sequence,
        address sender,
        bytes32 refundAddress
    ) internal virtual override returns (TransceiverStructs.NativeTokenTransfer memory ntt) {
        ntt = super._prepareNativeTokenTransfer(
            amount, recipient, recipientChain, sequence, sender, refundAddress
        );
        ntt.additionalPayload = _getPayloadStorage().data;
    }
}
