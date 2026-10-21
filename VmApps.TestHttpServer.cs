// Loopback-only, one-request HTTP fixture. Never connects to a VCF server.
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading.Tasks;

namespace VmApps.Tests {
    public sealed class HttpServer : IDisposable {
        private readonly TcpListener listener;
        private readonly Task worker;
        public string Url { get; private set; }
        public string Request { get; private set; }
        public HttpServer(int status, string body) : this(status, body, null) {}
        public HttpServer(int status, string body, X509Certificate2 certificate) {
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Url = (certificate == null ? "http://127.0.0.1:" : "https://localhost:") +
                ((IPEndPoint)listener.LocalEndpoint).Port + "/";
            worker = Task.Run(() => {
                try {
                    using (var client = listener.AcceptTcpClient())
                    using (Stream stream = certificate == null ? (Stream)client.GetStream() :
                        new SslStream(client.GetStream(), false)) {
                        client.ReceiveTimeout = 5000;
                        if (certificate != null) {
                            try {
                                ((SslStream)stream).AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                            } catch (AuthenticationException) {
                                // Rejected certificates intentionally terminate the TLS handshake.
                                return;
                            } catch (IOException) {
                                return;
                            }
                        }
                        var header = new StringBuilder();
                        while (!header.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal)) {
                            int value = stream.ReadByte();
                            if (value < 0 && certificate != null && header.Length == 0) return;
                            if (value < 0) throw new IOException("Client closed before request headers");
                            header.Append((char)value);
                        }
                        string headers = header.ToString();
                        int length = 0;
                        foreach (string line in headers.Split(new[] { "\r\n" }, StringSplitOptions.None)) {
                            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                                length = Int32.Parse(line.Substring(15).Trim());
                        }
                        if (headers.IndexOf("Expect: 100-continue", StringComparison.OrdinalIgnoreCase) >= 0) {
                            byte[] ready = Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");
                            stream.Write(ready, 0, ready.Length);
                        }
                        byte[] payload = new byte[length];
                        int received = 0;
                        while (received < length) {
                            int count = stream.Read(payload, received, length - received);
                            if (count == 0) throw new IOException("Client closed before request body");
                            received += count;
                        }
                        Request = headers + Encoding.UTF8.GetString(payload);
                        byte[] bytes = Encoding.UTF8.GetBytes(body);
                        string response = "HTTP/1.1 " + status + " Test\r\nContent-Type: application/json\r\n" +
                            "Content-Length: " + bytes.Length + "\r\nConnection: close\r\n";
                        if (status == 302) response += "Location: " + Url + "redirected\r\n";
                        byte[] responseHeader = Encoding.ASCII.GetBytes(response + "\r\n");
                        stream.Write(responseHeader, 0, responseHeader.Length);
                        stream.Write(bytes, 0, bytes.Length);
                    }
                } catch (SocketException) {
                    // Stopping the fixture interrupts AcceptTcpClient if no request was sent.
                    if (listener.Server.IsBound) throw;
                }
            });
        }
        public void Dispose() {
            listener.Stop();
            if (!worker.Wait(7000)) throw new TimeoutException("Loopback fixture did not stop");
        }
    }
}
