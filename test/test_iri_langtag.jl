@testset "IRI Validation" begin
    # Valid IRIs
    @test validate_iri("http://example.org/resource")
    @test validate_iri("https://example.org/path?query=1#frag")
    @test validate_iri("urn:isbn:0451450523")
    @test validate_iri("mailto:user@example.org")
    @test validate_iri("ftp://ftp.example.org/file")
    @test validate_iri("http://example.org/path%20with%20spaces")
    @test validate_iri("http://example.org/a+b-c.d")
    @test validate_iri("custom+scheme://host/path")

    # Invalid IRIs
    @test !validate_iri("")
    @test !validate_iri("no-scheme")
    @test !validate_iri("://missing-scheme")
    @test !validate_iri("http://example.org/path with spaces")
    @test !validate_iri("http://example.org/bad%GG")
    @test !validate_iri("http://example.org/<bad>")
    @test !validate_iri("http://example.org/{bad}")
    @test !validate_iri("1bad://example.org")

    # validate_iri! throws on invalid
    @test_throws ArgumentError validate_iri!("not a valid iri")
    @test isnothing(validate_iri!("http://example.org/ok"))
end

@testset "IRI Parsing" begin
    p = parse_iri("http://example.org/path?q=1#frag")
    @test p.scheme == "http"
    @test p.authority == "example.org"
    @test p.path == "/path"
    @test p.query == "q=1"
    @test p.fragment == "frag"

    p2 = parse_iri("urn:isbn:0451450523")
    @test p2.scheme == "urn"
    @test isnothing(p2.authority)
    @test p2.path == "isbn:0451450523"
    @test isnothing(p2.query)
    @test isnothing(p2.fragment)

    p3 = parse_iri("mailto:user@example.org")
    @test p3.scheme == "mailto"
    @test p3.path == "user@example.org"

    p4 = parse_iri("https://host:8080/path")
    @test p4.scheme == "https"
    @test p4.authority == "host:8080"
    @test p4.path == "/path"
end

@testset "Language Tag Validation" begin
    # Valid tags
    @test validate_langtag("en")
    @test validate_langtag("en-US")
    @test validate_langtag("zh-Hans")
    @test validate_langtag("zh-Hans-CN")
    @test validate_langtag("de-DE")
    @test validate_langtag("sr-Latn")
    @test validate_langtag("es-419")

    # 4-8 character primary language subtags (RFC 5646)
    @test validate_langtag("abcd")
    @test validate_langtag("abcde")
    @test validate_langtag("abcdefgh")

    # Extended language subtags
    @test validate_langtag("zh-cmn-Hans-CN")
    @test validate_langtag("zh-yue")

    # Variants
    @test validate_langtag("sl-rozaj")
    @test validate_langtag("de-CH-1901")

    # Extension singletons
    @test validate_langtag("en-a-bbb")
    @test validate_langtag("en-a-bbb-x-y")
    @test validate_langtag("en-u-islamcal")
    @test validate_langtag("zh-CN-a-myext-x-private")

    # Private-use subtags
    @test validate_langtag("de-x-foo")
    @test validate_langtag("en-US-x-twain")
    @test validate_langtag("x-private")
    @test validate_langtag("x-a-b-c")

    # Invalid tags
    @test !validate_langtag("")
    @test !validate_langtag("x")           # private-use marker without subtags
    @test !validate_langtag("toolonglangtag")  # too long for primary
    @test !validate_langtag("en_US")       # underscore not allowed
    @test !validate_langtag("123")         # must start with letters
    @test !validate_langtag("en-")         # trailing hyphen
    @test !validate_langtag("en-a")        # extension singleton with no subtag
    @test !validate_langtag("de-x")        # private-use marker with no subtag
    @test !validate_langtag("en-a-b")      # extension subtag too short (1 char)
    @test !validate_langtag("a-x-foo")     # primary subtag too short
end

@testset "Language Tag Normalization" begin
    @test normalize_langtag("en-us") == "en-US"
    @test normalize_langtag("zh-hans-cn") == "zh-Hans-CN"
    @test normalize_langtag("EN-US") == "en-US"
    @test normalize_langtag("sr-latn") == "sr-Latn"
    @test normalize_langtag("de-de") == "de-DE"
    @test normalize_langtag("es-419") == "es-419"
    @test normalize_langtag("en") == "en"

    # Subtags after a singleton stay lowercase (no fake script/region casing)
    @test normalize_langtag("de-x-FOO") == "de-x-foo"
    @test normalize_langtag("en-US-x-TWAIN") == "en-US-x-twain"
    @test normalize_langtag("en-A-BBB-X-AB") == "en-a-bbb-x-ab"
    @test normalize_langtag("X-PRIV") == "x-priv"

    # normalize and validate agree: normalized valid tags stay valid
    for tag in ["en-us", "zh-hans-cn", "de-x-FOO", "en-A-BBB-X-AB",
                "EN-US-X-TWAIN", "es-419", "x-private"]
        @test validate_langtag(tag)
        @test validate_langtag(normalize_langtag(tag))
    end
end
