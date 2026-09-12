class Aviary < Formula
  desc "Swift CLI for posting and reading Twitter/X"
  homepage "https://github.com/local/aviary"
  version "0.8.0"
  url "file://#{Pathname.new(__dir__).parent}"
  sha256 :no_check
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "-c", "release", "--product", "aviary", "--disable-sandbox"
    bin_path = `swift build -c release --product aviary --show-bin-path`.strip
    bin.install "#{bin_path}/aviary"
  end

  test do
    help = shell_output("#{bin}/aviary --help")
    assert_match "whoami", help
  end
end
