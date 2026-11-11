// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @notice ERC-8021 transaction attribution, schema 0 (canonical code registry).
/// @dev Layout, read from the end of calldata backwards:
///      codes (ASCII, comma-separated) | codesLength (1 byte) | schemaId (1 byte, 0x00) | ercMarker (16 bytes)
library BuilderCode {
    /// @dev The 16-byte ERC-8021 marker, 0x8021 repeated eight times.
    bytes16 internal constant ERC_MARKER = 0x80218021802180218021802180218021;

    /// @dev The NCTR Alliance Builder Code. bc_kry3r4sw is retired and must never be used.
    string internal constant CODE = "bc_90w5bpx5";

    error CodeTooLong();
    error EmptyCode();

    function suffix(string memory code) internal pure returns (bytes memory) {
        bytes memory c = bytes(code);
        if (c.length == 0) revert EmptyCode();
        if (c.length > 255) revert CodeTooLong();
        return abi.encodePacked(c, uint8(c.length), uint8(0), ERC_MARKER);
    }

    function suffix() internal pure returns (bytes memory) {
        return suffix(CODE);
    }

    /// @notice True when `data` ends with the schema-0 suffix for `code`.
    function hasSuffix(bytes memory data, string memory code) internal pure returns (bool) {
        bytes memory s = suffix(code);
        if (data.length < s.length) return false;
        uint256 offset = data.length - s.length;
        for (uint256 i = 0; i < s.length; i++) {
            if (data[offset + i] != s[i]) return false;
        }
        return true;
    }
}
