//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Testing
@testable import ContainerComposeCore

@Suite("Shell Tokenize Tests")
struct ShellTokenizeTests {

    @Test("Empty string tokenizes to empty argv")
    func emptyStringTokenizesToEmptyArgv() throws {
        #expect(try posixShellTokenize("") == [])
    }

    @Test("Whitespace-only string tokenizes to empty argv")
    func whitespaceOnlyStringTokenizesToEmptyArgv() throws {
        #expect(try posixShellTokenize("   \t\t  ") == [])
    }

    @Test("Single token remains one argv element")
    func singleTokenRemainsOneArgvElement() throws {
        #expect(try posixShellTokenize("python") == ["python"])
    }

    @Test("Simple command string splits on whitespace")
    func simpleCommandStringSplitsOnWhitespace() throws {
        #expect(try posixShellTokenize("python -m http.server 8000") == ["python", "-m", "http.server", "8000"])
    }

    @Test("Multiple whitespace characters collapse between tokens")
    func multipleWhitespaceCharactersCollapseBetweenTokens() throws {
        #expect(try posixShellTokenize("a   b\t\tc") == ["a", "b", "c"])
    }

    @Test("Single quotes preserve spaces")
    func singleQuotesPreserveSpaces() throws {
        #expect(try posixShellTokenize("echo 'hello world'") == ["echo", "hello world"])
    }

    @Test("Double quotes preserve spaces")
    func doubleQuotesPreserveSpaces() throws {
        #expect(try posixShellTokenize("echo \"hello world\"") == ["echo", "hello world"])
    }

    @Test("Backslash escapes spaces")
    func backslashEscapesSpaces() throws {
        #expect(try posixShellTokenize("echo hello\\ world") == ["echo", "hello world"])
    }

    @Test("Backslash escapes double quotes")
    func backslashEscapesDoubleQuotes() throws {
        #expect(try posixShellTokenize("echo \\\"quoted\\\"") == ["echo", "\"quoted\""])
    }

    @Test("Single quotes preserve double quotes literally")
    func singleQuotesPreserveDoubleQuotesLiterally() throws {
        #expect(try posixShellTokenize("echo '\"raw\"'") == ["echo", "\"raw\""])
    }

    @Test("Mixed shell command preserves quoted script")
    func mixedShellCommandPreservesQuotedScript() throws {
        #expect(try posixShellTokenize("sh -c 'echo hi && exit 0'") == ["sh", "-c", "echo hi && exit 0"])
    }

    @Test("Leading and trailing whitespace is ignored")
    func leadingAndTrailingWhitespaceIsIgnored() throws {
        #expect(try posixShellTokenize("  python  ") == ["python"])
    }

    @Test("Unterminated single quote throws tokenization error")
    func unterminatedSingleQuoteThrowsTokenizationError() throws {
        #expect(throws: ComposeError.self) {
            try posixShellTokenize("echo 'hello")
        }
    }

    @Test("Unterminated double quote throws tokenization error")
    func unterminatedDoubleQuoteThrowsTokenizationError() throws {
        #expect(throws: ComposeError.self) {
            try posixShellTokenize("echo \"hello")
        }
    }

    @Test("Trailing backslash throws tokenization error")
    func trailingBackslashThrowsTokenizationError() throws {
        #expect(throws: ComposeError.self) {
            try posixShellTokenize("echo hello\\")
        }
    }

    // MARK: - CHAOS-1437 — newline handling

    /// Repro for CHAOS-1437. A YAML folded scalar (`command: > ...`) decodes
    /// with a trailing real newline. Without newline-as-separator handling,
    /// that `\n` rides along on the last argv token, producing
    /// `allkeys-lru\n` which valkey rejects:
    ///
    ///     valkey: >>> 'maxmemory-policy "allkeys-lru\n"'
    ///
    /// POSIX shells split on `IFS = <space><tab><newline>` by default, so the
    /// tokenizer must do the same.
    @Test("CHAOS-1437: trailing newline does not bleed into last token")
    func trailingNewlineDoesNotBleedIntoLastToken() throws {
        #expect(
            try posixShellTokenize("valkey-server --maxmemory-policy allkeys-lru\n")
                == ["valkey-server", "--maxmemory-policy", "allkeys-lru"]
        )
    }

    @Test("CHAOS-1437: newline splits tokens like space/tab")
    func newlineSplitsTokensLikeSpaceOrTab() throws {
        #expect(try posixShellTokenize("a\nb\nc") == ["a", "b", "c"])
    }

    @Test("CHAOS-1437: mixed newline and space whitespace collapses")
    func mixedNewlineAndSpaceWhitespaceCollapses() throws {
        #expect(try posixShellTokenize("a \n b\t\nc") == ["a", "b", "c"])
    }

    @Test("CHAOS-1437: carriage-return is also a token separator")
    func carriageReturnIsAlsoATokenSeparator() throws {
        #expect(try posixShellTokenize("a\r\nb") == ["a", "b"])
    }

    @Test("CHAOS-1437: single-quoted newline is preserved literally")
    func singleQuotedNewlineIsPreservedLiterally() throws {
        // Single-quotes preserve newlines as-is — same as POSIX shells.
        // Round-trip check: the embedded newline survives quoting.
        #expect(try posixShellTokenize("echo 'line1\nline2'") == ["echo", "line1\nline2"])
    }
}
