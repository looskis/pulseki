class Pulseki < Formula
  desc "Prometheus exporter for macOS: CPU, GPU, memory, disk, network, sensors, battery"
  homepage "https://github.com/looskis/pulseki"
  url "https://github.com/looskis/pulseki/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "9a5813a3e49b09beec9e1927ccfdbff874c32dbcd0eb641c4fb531f64b00f58e"
  license "MIT"
  head "https://github.com/looskis/pulseki.git", branch: "main"

  depends_on macos: :ventura
  uses_from_macos "swift" => :build

  def install
    system "swift", "build", "--disable-sandbox", "--configuration", "release", "--product", "pulseki"
    bin.install ".build/release/pulseki"
    etc.install "config/pulseki.conf"
  end

  def caveats
    <<~EOS
      pulseki serves metrics on http://0.0.0.0:9101/metrics by default.
      Edit #{etc}/pulseki.conf to change the address or disable collectors.

      Start at login:
        brew services start pulseki

      Start at boot, before anyone logs in (for always-on machines):
        sudo brew services start pulseki
    EOS
  end

  service do
    run [opt_bin/"pulseki", "--config", etc/"pulseki.conf"]
    keep_alive true
    log_path var/"log/pulseki.log"
    error_log_path var/"log/pulseki.err"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/pulseki --version")
    assert_match "smc", shell_output("#{bin}/pulseki --collectors")

    port = free_port
    pid = fork { exec bin/"pulseki", "--listen", "127.0.0.1:#{port}", "--disable", "smc" }
    sleep 2
    begin
      output = shell_output("curl -sf http://127.0.0.1:#{port}/metrics")
      assert_match "node_cpu_seconds_total", output
      assert_match "node_memory_total_bytes", output
      assert_match "pulseki_build_info", output
    ensure
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end
end
