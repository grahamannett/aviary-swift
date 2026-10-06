# Source bootstrap only. Release formulas are generated with real archive checksums
# by scripts/render-homebrew-formula.py in grahamannett/homebrew-tap.
class Aviary < Formula
  desc "Bird-compatible CLI for reading and posting on X"
  homepage "https://github.com/grahamannett/aviary-swift"
  head "https://github.com/grahamannett/aviary-swift.git", branch: "main"

  depends_on :macos
  depends_on xcode: ["16.3", :build]

  def install
    system "swift", "build", "-c", "release", "--product", "aviary", "--disable-sandbox"
    system "swift", "build", "-c", "release", "--product", "AviarySelfTest", "--disable-sandbox"
    build_bin = Pathname.new(Utils.safe_popen_read("swift", "build", "-c", "release", "--show-bin-path").strip)
    (libexec/"bin").install build_bin/"aviary"
    (libexec/"libexec").install build_bin/"AviarySelfTest" => "aviary-selftest"
    bundles = build_bin.glob("*_XClient.bundle")
    odie "Expected one XClient resource bundle" unless bundles.length == 1
    (libexec/"bin").install bundles.first
    (libexec/"share/doc/aviary").install "THIRD_PARTY_NOTICES.md"
    (libexec/"share/doc/aviary/dependencies").install "licenses/Bird-LICENSE.txt"
    bin.install_symlink libexec/"bin/aviary"
  end

  test do
    ENV["AVIARY_SKIP_QUERY_ID_REFRESH"] = "1"
    ENV["XDG_CONFIG_HOME"] = (testpath/"config").to_s
    assert_match "whoami", shell_output("#{bin}/aviary --help")
    assert_match "ok ", shell_output("#{libexec}/libexec/aviary-selftest --resources-only")
    assert_match '"features"', shell_output("#{bin}/aviary query-ids --json")
  end
end
