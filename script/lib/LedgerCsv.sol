// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @notice Minimal CSV reader for the migration ledger.
/// @dev Handles RFC 4180 quoting (fields wrapped in double quotes may contain commas,
///      and "" inside a quoted field is a literal quote). Lines end with \n or \r\n.
library LedgerCsv {
    error UnterminatedQuote(uint256 line);
    error BadDecimal(string value);
    error TooManyDecimals(string value);

    /// @notice Split the whole file into rows of fields.
    function parse(string memory text) internal pure returns (string[][] memory rows) {
        bytes memory b = bytes(text);
        // Count lines first (upper bound on rows).
        uint256 maxRows = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "\n") maxRows++;
        }
        rows = new string[][](maxRows);
        uint256 rowCount;
        uint256 i;
        while (i < b.length) {
            (string[] memory fields, uint256 next) = _parseLine(b, i, rowCount + 1);
            i = next;
            // Skip blank lines.
            if (fields.length == 1 && bytes(fields[0]).length == 0) continue;
            rows[rowCount++] = fields;
        }
        assembly {
            mstore(rows, rowCount)
        }
    }

    function _parseLine(bytes memory b, uint256 start, uint256 lineNo)
        private
        pure
        returns (string[] memory fields, uint256 next)
    {
        // Upper bound on fields: commas on this line + 1.
        uint256 maxFields = 1;
        for (uint256 j = start; j < b.length && b[j] != "\n"; j++) {
            if (b[j] == ",") maxFields++;
        }
        fields = new string[](maxFields);
        uint256 n;
        uint256 i = start;
        bytes memory buf = new bytes(0);
        bool inQuotes;
        while (i < b.length) {
            bytes1 ch = b[i];
            if (inQuotes) {
                if (ch == '"') {
                    if (i + 1 < b.length && b[i + 1] == '"') {
                        buf = abi.encodePacked(buf, '"');
                        i += 2;
                        continue;
                    }
                    inQuotes = false;
                    i++;
                    continue;
                }
                buf = abi.encodePacked(buf, ch);
                i++;
                continue;
            }
            if (ch == '"') {
                inQuotes = true;
                i++;
                continue;
            }
            if (ch == ",") {
                fields[n++] = string(buf);
                buf = new bytes(0);
                i++;
                continue;
            }
            if (ch == "\r") {
                i++;
                continue;
            }
            if (ch == "\n") {
                i++;
                break;
            }
            buf = abi.encodePacked(buf, ch);
            i++;
        }
        if (inQuotes) revert UnterminatedQuote(lineNo);
        fields[n++] = string(buf);
        assembly {
            mstore(fields, n)
        }
        next = i;
    }

    /// @notice Index of `name` in the header row, or type(uint256).max if absent.
    function column(string[] memory header, string memory name) internal pure returns (uint256) {
        bytes32 h = keccak256(bytes(name));
        for (uint256 i = 0; i < header.length; i++) {
            if (keccak256(bytes(header[i])) == h) return i;
        }
        return type(uint256).max;
    }

    /// @notice Parse a non-negative decimal string ("123", "123.4", "0.000001") into 18-decimal units.
    function toWei(string memory value) internal pure returns (uint256 result) {
        bytes memory b = bytes(value);
        if (b.length == 0) revert BadDecimal(value);
        uint256 intPart;
        uint256 frac;
        uint256 fracDigits;
        bool seenDot;
        bool seenDigit;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 ch = b[i];
            if (ch == ".") {
                if (seenDot) revert BadDecimal(value);
                seenDot = true;
                continue;
            }
            if (ch < "0" || ch > "9") revert BadDecimal(value);
            seenDigit = true;
            uint256 d = uint8(ch) - 48;
            if (seenDot) {
                if (fracDigits == 18) revert TooManyDecimals(value);
                frac = frac * 10 + d;
                fracDigits++;
            } else {
                intPart = intPart * 10 + d;
            }
        }
        if (!seenDigit) revert BadDecimal(value);
        result = intPart * 1e18 + frac * (10 ** (18 - fracDigits));
    }
}
