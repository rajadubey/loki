import Foundation
import Testing
@testable import LokiCore

private let includePath = "/opt/homebrew/etc/nginx/remote.conf"
private let addedLine = "    include /opt/homebrew/etc/nginx/remote.conf;  # added by loki"

@Suite struct StreamIncludeTests {
    // MARK: isConfigured

    @Test func configuredInStreamBlock() {
        let conf = """
        worker_processes 1;
        events { worker_connections 1024; }
        http {
            server { listen 8080; }
        }
        stream {
            include /opt/homebrew/etc/nginx/remote.conf;
        }
        """
        #expect(StreamInclude.isConfigured(in: conf))
    }

    @Test func configuredOnOneLine() {
        #expect(StreamInclude.isConfigured(in: "stream { include remote.conf; }\n"))
        #expect(StreamInclude.isConfigured(in: "stream{include remote.conf;}"))
    }

    @Test func relativeInclude() {
        #expect(StreamInclude.isConfigured(in: "stream {\n  include remote.conf;\n}\n"))
        #expect(StreamInclude.isConfigured(in: "stream {\n  include  servers/remote.conf ;\n}\n"))
    }

    @Test func quotedPath() {
        #expect(StreamInclude.isConfigured(in: "stream {\n    include \"/opt/homebrew/etc/nginx/remote.conf\";\n}\n"))
        #expect(StreamInclude.isConfigured(in: "stream {\n    include '/etc/nginx/remote.conf';\n}\n"))
    }

    @Test func hashInsideQuotesIsNotAComment() {
        #expect(StreamInclude.isConfigured(in: "stream {\n    include \"/srv/a#b/remote.conf\";\n}\n"))
        // ...while a comment containing quotes doesn't open a string
        #expect(StreamInclude.isConfigured(in: "# don't \"forget\"\nstream {\n    include remote.conf;\n}\n"))
    }

    @Test func commentedOutIncludeIsNotConfigured() {
        #expect(!StreamInclude.isConfigured(in: "stream {\n    # include /opt/homebrew/etc/nginx/remote.conf;\n}\n"))
        #expect(!StreamInclude.isConfigured(in: "stream {\n    #include remote.conf;\n}\n"))
        #expect(!StreamInclude.isConfigured(in: "#stream {\n#    include remote.conf;\n#}\n"))
    }

    @Test func includeInsideHttpOnlyIsNotConfigured() {
        let conf = """
        http {
            include mime.types;
            include /opt/homebrew/etc/nginx/remote.conf;
            server { listen 80; }
        }
        """
        #expect(!StreamInclude.isConfigured(in: conf))
    }

    @Test func otherIncludesDontCount() {
        #expect(!StreamInclude.isConfigured(in: "stream {\n    include servers/*;\n}\n"))
        #expect(!StreamInclude.isConfigured(in: "stream {\n    include remote.conf.bak;\n}\n"))
        #expect(!StreamInclude.isConfigured(in: "stream {\n    upstream remote.conf { server 1.2.3.4:80; }\n}\n"))
        #expect(!StreamInclude.isConfigured(in: ""))
    }

    @Test func upstreamIsNotStream() {
        #expect(!StreamInclude.isConfigured(in: "upstream {\n    include remote.conf;\n}\n"))
    }

    @Test func multipleStreamBlocks() {
        let conf = """
        stream {
            server { listen 9000; proxy_pass 1.2.3.4:9000; }
        }
        http { }
        stream {
            include remote.conf;
        }
        """
        #expect(StreamInclude.isConfigured(in: conf))
        #expect(StreamInclude.streamBodies(StreamInclude.stripComments(conf)).count == 2)
    }

    @Test func nestedStreamWordInsideHttpIsIgnored() {
        // only top-level stream blocks count
        #expect(StreamInclude.streamOpenBraces("http {\n stream {\n include remote.conf;\n }\n}\n").isEmpty)
        #expect(!StreamInclude.isConfigured(in: "http {\n stream {\n include remote.conf;\n }\n}\n"))
    }

    @Test func crlfLineEndings() {
        let conf = "# loki test\r\nevents {}\r\nstream {\r\n    include remote.conf;\r\n}\r\n"
        #expect(StreamInclude.isConfigured(in: conf))
        #expect(!StreamInclude.isConfigured(in: "stream {\r\n    # include remote.conf;\r\n}\r\n"))
    }

    // MARK: stripComments

    @Test func stripCommentsKeepsCharacterCountAndLines() {
        let text = "a # cömment ✅\n\"b#c\" 'd#e' # x\r\nf"
        let stripped = StreamInclude.stripComments(text)
        #expect(stripped.count == text.count)
        #expect(stripped == "a " + String(repeating: " ", count: 11) + "\n\"b#c\" 'd#e' " + "   " + "\r\nf")
    }

    // MARK: adding

    @Test func addsIntoExistingStreamBlock() {
        let conf = "events {}\nstream {\n    server { listen 9000; proxy_pass 1.2.3.4:9000; }\n}\nhttp {}\n"
        let expected = "events {}\nstream {\n\(addedLine)\n    server { listen 9000; proxy_pass 1.2.3.4:9000; }\n}\nhttp {}\n"
        #expect(StreamInclude.adding(to: conf, includePath: includePath) == expected)
    }

    @Test func addsIntoFirstOfSeveralStreamBlocks() {
        let conf = "stream {\n}\nstream {\n}\n"
        #expect(StreamInclude.adding(to: conf, includePath: includePath) == "stream {\n\(addedLine)\n}\nstream {\n}\n")
    }

    @Test func addsBesideACommentedOutInclude() {
        let conf = "stream {\n    # include \(includePath);\n}\n"
        let out = StreamInclude.adding(to: conf, includePath: includePath)
        #expect(out == "stream {\n\(addedLine)\n    # include \(includePath);\n}\n")
        #expect(StreamInclude.isConfigured(in: out))
    }

    @Test func appendsNewBlockWhenThereIsNone() {
        let conf = "events {}\nhttp {\n    include \(includePath);\n}\n"
        let out = StreamInclude.adding(to: conf, includePath: includePath)
        #expect(out == conf + "\n# TCP proxies managed by loki\nstream {\n\(addedLine)\n}\n")
        #expect(StreamInclude.isConfigured(in: out))
    }

    @Test func appendsToFileWithoutTrailingNewline() {
        let out = StreamInclude.adding(to: "events {}", includePath: includePath)
        #expect(out == "events {}\n\n# TCP proxies managed by loki\nstream {\n\(addedLine)\n}\n")
    }

    @Test func appendsToEmptyFile() {
        #expect(StreamInclude.adding(to: "", includePath: includePath) == "\n# TCP proxies managed by loki\nstream {\n\(addedLine)\n}\n")
    }

    @Test func commentedOutStreamBlockGetsANewBlock() {
        let conf = "#stream {\n#}\n"
        #expect(StreamInclude.adding(to: conf, includePath: includePath) == conf + "\n# TCP proxies managed by loki\nstream {\n\(addedLine)\n}\n")
    }

    @Test func addingIsIdempotent() {
        for conf in ["events {}\n", "stream {\n}\n", "", "stream { include remote.conf; }\n"] {
            let once = StreamInclude.adding(to: conf, includePath: includePath)
            #expect(StreamInclude.isConfigured(in: once))
            #expect(StreamInclude.adding(to: once, includePath: includePath) == once)
        }
    }

    @Test func alreadyConfiguredIsUnchanged() {
        let conf = "stream {\n    include \"\(includePath)\";\n}"
        #expect(StreamInclude.adding(to: conf, includePath: includePath) == conf)
    }

    @Test func nonASCIIBeforeTheStreamBlockMapsToTheRightPlace() {
        // Multi-byte and multi-scalar characters (é, emoji with variation selector, flag, CJK, combining accent)
        // before the block must not shift where the include goes.
        let conf = "# café ☕️ 🇩🇪 日本語 e\u{301}\nhttp { server_name \"ünïcødé.example\"; }\nstream {\n    server { listen 1; }\n}\n"
        let expected = "# café ☕️ 🇩🇪 日本語 e\u{301}\nhttp { server_name \"ünïcødé.example\"; }\nstream {\n\(addedLine)\n    server { listen 1; }\n}\n"
        #expect(StreamInclude.adding(to: conf, includePath: includePath) == expected)
    }

    @Test func crlfFileGetsTheIncludeInsideItsStreamBlock() {
        let conf = "# comment\r\nstream {\r\n}\r\n"
        let out = StreamInclude.adding(to: conf, includePath: includePath)
        #expect(out == "# comment\r\nstream {\n\(addedLine)\r\n}\r\n")
        #expect(StreamInclude.isConfigured(in: out))
    }
}
