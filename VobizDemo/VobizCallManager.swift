import Foundation
import AVFoundation
import WebKit

enum CallState: String {
    case idle = "Idle"
    case creatingSession = "Creating Session"
    case registeringSIP = "Registering (Media)"
    case registeredSIP = "Registered (Media Ready)"
    case ringingCelebrity = "Celebrity Ringing"
    case connected = "Connected"
    case ending = "Ending Call"
    case failed = "Failed"
}

protocol VobizCallManagerDelegate: AnyObject {
    func callStateChanged(to state: CallState)
    func logAdded(_ log: String)
}

final class VobizCallManager: NSObject, ObservableObject {
    @Published var state: CallState = .idle {
        didSet {
            delegate?.callStateChanged(to: state)
            addLog("State changed to: \(state.rawValue)")
        }
    }
    @Published var logs: [String] = []
    
    weak var delegate: VobizCallManagerDelegate?
    
    private var webView: WKWebView?
    private var activeSessionId: String?
    private var activeTicketId: String?
    private var backendBaseURL: String = ""
    private var isMuted = false
    
    private let scriptMessageNames = [
        "vobizOnRegistered",
        "vobizOnLoginFailed",
        "vobizOnIncomingCall",
        "vobizOnCallAnswered",
        "vobizOnRemoteAudioAttached",
        "vobizOnCallFailed",
        "vobizOnCallTerminated",
        "vobizLog"
    ]
    
    func startCall(backendURL: String, fanId: String, celebrityId: String) {
        guard state == .idle || state == .failed else {
            addLog("⚠️ Cannot start call: current state is \(state.rawValue)")
            return
        }
        
        self.backendBaseURL = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.backendBaseURL.hasSuffix("/") {
            self.backendBaseURL.removeLast()
        }
        
        addLog("🚀 Starting Vobiz call flow...")
        addLog("Backend: \(self.backendBaseURL)")
        addLog("Fan ID: \(fanId)")
        addLog("Celebrity ID: \(celebrityId)")
        
        ensureMicrophonePermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.addLog("❌ Microphone permission denied!")
                self.state = .failed
                return
            }
            
            self.configureAudioSession()
            self.createVoiceSession(fanId: fanId, celebrityId: celebrityId)
        }
    }
    
    func endCall() {
        guard state != .idle else { return }
        state = .ending
        addLog("📴 Hanging up call...")
        
        // 1. Tell WKWebView to hangup & logout / disconnect
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.webView?.evaluateJavaScript("window.fancallHangup && window.fancallHangup(); window.fancallLogout && window.fancallLogout();", completionHandler: nil)
        }
        
        // 2. Notify backend that session is ended
        if let sessionId = activeSessionId {
            notifyBackendCallEnded(sessionId: sessionId)
        } else {
            cleanup()
        }
    }
    
    func setMuted(_ muted: Bool) {
        self.isMuted = muted
        addLog(muted ? "🎙️ Muting microphone" : "🎙️ Unmuting microphone")
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.fancallSetMuted && window.fancallSetMuted(\(muted ? "true" : "false"));", completionHandler: nil)
        }
    }
    
    func toggleSpeaker(_ useSpeaker: Bool) {
        addLog(useSpeaker ? "🔊 Switching to Speaker" : "🎧 Switching to Earpiece")
        let session = AVAudioSession.sharedInstance()
        do {
            if useSpeaker {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
        } catch {
            addLog("⚠️ Failed to toggle speaker: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Audio Session Management
    
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setActive(true)
            addLog("🎧 AVAudioSession configured: playAndRecord, voiceChat, allowBluetoothHFP")
        } catch {
            addLog("⚠️ Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
    }
    
    private func ensureMicrophonePermission(completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            session.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        @unknown default:
            completion(false)
        }
    }
    
    // MARK: - Backend REST Integration
    
    private func createVoiceSession(fanId: String, celebrityId: String) {
        state = .creatingSession
        
        let urlString = "\(backendBaseURL)/api/v3/voice/sessions"
        guard let url = URL(string: urlString) else {
            addLog("❌ Invalid URL: \(urlString)")
            state = .failed
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "fan_id": fanId,
            "celebrity_id": celebrityId
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            addLog("❌ Failed to serialize request body: \(error.localizedDescription)")
            state = .failed
            return
        }
        
        addLog("POSTing to /api/v3/voice/sessions...")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let error = error {
                    self.addLog("❌ Network error: \(error.localizedDescription)")
                    self.state = .failed
                    return
                }
                
                guard let data = data else {
                    self.addLog("❌ Empty response from server")
                    self.state = .failed
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 201 && httpResponse.statusCode != 200 {
                    let bodyStr = String(data: data, encoding: .utf8) ?? ""
                    self.addLog("❌ HTTP \(httpResponse.statusCode) from backend: \(bodyStr)")
                    self.state = .failed
                    return
                }
                
                do {
                    guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                        self.addLog("❌ Invalid JSON response")
                        self.state = .failed
                        return
                    }
                    
                    self.addLog("✅ Voice session created successfully!")
                    self.parseSessionResponse(json)
                    
                } catch {
                    self.addLog("❌ Failed to parse JSON: \(error.localizedDescription)")
                    self.state = .failed
                }
            }
        }.resume()
    }
    
    private func parseSessionResponse(_ json: [String: Any]) {
        guard let session = json["session"] as? [String: Any] else {
            addLog("❌ Missing 'session' object in response")
            state = .failed
            return
        }
        
        guard let sessionId = session["id"] as? String else {
            addLog("❌ Missing session 'id'")
            state = .failed
            return
        }
        
        self.activeSessionId = sessionId
        self.activeTicketId = session["booking_id"] as? String
        
        guard let providerPayload = session["provider_payload"] as? [String: Any] else {
            addLog("❌ Missing 'provider_payload' in session")
            state = .failed
            return
        }
        
        let provider = providerPayload["provider"] as? String ?? ""
        let mediaMode = providerPayload["media_mode"] as? String ?? ""
        
        addLog("Session ID: \(sessionId)")
        addLog("Provider: \(provider), Media Mode: \(mediaMode)")
        
        if provider == "native_webrtc" {
            // WebRTC Mode (Dynamic Room via WebSocket)
            guard let webrtc = providerPayload["webrtc"] as? [String: Any],
                  let roomId = webrtc["roomId"] as? String,
                  let token = webrtc["token"] as? String,
                  let signalingUrl = webrtc["signalingUrl"] as? String else {
                addLog("❌ Missing 'webrtc' parameters in provider_payload")
                state = .failed
                return
            }
            
            let iceServers = webrtc["iceServers"] as? [[String: Any]] ?? []
            addLog("🗝️ WebRTC Room Credentials received:")
            addLog("   Room ID: \(roomId)")
            addLog("   Signaling URL: \(signalingUrl)")
            addLog("   ICE Servers Count: \(iceServers.count)")
            
            registerWebRTCMode(roomId: roomId, token: token, signalingUrl: signalingUrl, iceServers: iceServers)
            
        } else if provider == "vobiz_pstn" {
            // SIP Mode
            guard let sip = providerPayload["sip"] as? [String: Any],
                  let username = sip["username"] as? String,
                  let password = sip["password"] as? String,
                  let uri = sip["uri"] as? String,
                  let domain = sip["domain"] as? String else {
                addLog("❌ Missing SIP credentials in provider_payload")
                state = .failed
                return
            }
            
            addLog("🗝️ SIP Credentials received:")
            addLog("   Username: \(username)")
            addLog("   Domain: \(domain)")
            addLog("   URI: \(uri)")
            
            registerSIPMode(username: username, password: password, domain: domain)
            
        } else {
            addLog("❌ Backend returned unsupported provider: \(provider)")
            state = .failed
        }
    }
    
    // MARK: - WKWebView Registration Methods
    
    private func registerSIPMode(username: String, password: String, domain: String) {
        state = .registeringSIP
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cleanupWebView()
            
            let contentController = WKUserContentController()
            self.scriptMessageNames.forEach { contentController.add(self, name: $0) }
            
            let config = WKWebViewConfiguration()
            config.userContentController = contentController
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
            webView.isOpaque = false
            webView.alpha = 0.01
            webView.backgroundColor = .clear
            webView.navigationDelegate = self
            webView.uiDelegate = self
            self.webView = webView
            
            if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
                window.addSubview(webView)
                window.sendSubviewToBack(webView)
            }
            
            let htmlContent = self.htmlStringSIP(username: username, password: password, domain: domain)
            webView.loadHTMLString(htmlContent, baseURL: URL(string: "https://vobiz-demo.local/"))
            self.addLog("🌐 WKWebView initialized and loaded with VoBiz SIP Client")
        }
    }
    
    private func registerWebRTCMode(roomId: String, token: String, signalingUrl: String, iceServers: [[String: Any]]) {
        state = .registeringSIP
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cleanupWebView()
            
            let contentController = WKUserContentController()
            self.scriptMessageNames.forEach { contentController.add(self, name: $0) }
            
            let config = WKWebViewConfiguration()
            config.userContentController = contentController
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
            webView.isOpaque = false
            webView.alpha = 0.01
            webView.backgroundColor = .clear
            webView.navigationDelegate = self
            webView.uiDelegate = self
            self.webView = webView
            
            if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
                window.addSubview(webView)
                window.sendSubviewToBack(webView)
            }
            
            let htmlContent = self.htmlStringWebRTC(roomId: roomId, token: token, signalingUrl: signalingUrl, iceServers: iceServers)
            webView.loadHTMLString(htmlContent, baseURL: URL(string: "https://vobiz-demo.local/"))
            self.addLog("🌐 WKWebView initialized and loaded with WebSocket WebRTC signaling container")
        }
    }
    
    private func notifyBackendMediaReady(sessionId: String) {
        state = .registeredSIP
        addLog("🔔 Notifying backend that fan media is ready...")
        
        let urlString = "\(backendBaseURL)/api/v3/voice/sessions/\(sessionId)/media-ready"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.addLog("❌ Media Ready notification failed: \(error.localizedDescription)")
                    self.state = .failed
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    self.addLog("❌ Media Ready HTTP \(httpResponse.statusCode): \(bodyStr)")
                    self.state = .failed
                    return
                }
                
                self.addLog("✅ Backend notified! Celebrity phone is now being dialed via PSTN cellular call...")
                self.state = .ringingCelebrity
            }
        }.resume()
    }
    
    private func notifyBackendCallEnded(sessionId: String) {
        addLog("🔔 Notifying backend that call has ended...")
        
        let urlString = "\(backendBaseURL)/api/v3/voice/sessions/\(sessionId)/end"
        guard let url = URL(string: urlString) else {
            self.cleanup()
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                self?.addLog("✅ Backend notified of call completion.")
                self?.cleanup()
            }
        }.resume()
    }
    
    // MARK: - Cleaning up
    
    private func cleanup() {
        addLog("🧼 Cleaning up active session...")
        cleanupWebView()
        activeSessionId = nil
        activeTicketId = nil
        isMuted = false
        state = .idle
    }
    
    private func cleanupWebView() {
        if let webView = self.webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            scriptMessageNames.forEach {
                webView.configuration.userContentController.removeScriptMessageHandler(forName: $0)
            }
            webView.removeFromSuperview()
        }
        self.webView = nil
    }
    
    private func addLog(_ log: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let fullLog = "[\(timestamp)] \(log)"
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logs.append(fullLog)
            self.delegate?.logAdded(fullLog)
            print("VobizDemo: \(fullLog)")
        }
    }
    
    // MARK: - Web Page HTML Templates (SIP & WebRTC)
    
    private func htmlStringSIP(username: String, password: String, domain: String) -> String {
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <script src="https://unpkg.com/vobiz-webrtc-sdk@1.0.3/dist/vobiz-webrtc-sdk.min.js"></script>
        </head>
        <body>
          <h1 style="font-family:-apple-system,sans-serif; text-align:center; margin-top:20px;">SIP Audio Leg</h1>
          <audio id="fancallRemoteAudio" autoplay playsinline></audio>
          
          <script>
          (function () {
            const username = "\(username)";
            const password = "\(password)";
            let vobiz = null;
            let audioAttached = false;
            let answerRequested = false;

            function post(name, payload) {
              try {
                const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name];
                if (handler && handler.postMessage) handler.postMessage(payload);
              } catch (e) {}
            }

            function nativeLog(msg) { post('vobizLog', String(msg || '')); }

            window.fancallAnswer = function () {
              if (answerRequested) {
                nativeLog('answer() skipped: already requested');
                return;
              }
              answerRequested = true;
              try {
                if (vobiz && vobiz.client) vobiz.client.answer();
                nativeLog('answer() called');
              } catch (e) {
                nativeLog('answer failed: ' + e.message);
              }
            };

            window.fancallHangup = function () {
              try { if (vobiz && vobiz.client) vobiz.client.hangup(); } catch (e) {}
            };

            window.fancallLogout = function () {
              try { if (vobiz && vobiz.client) vobiz.client.logout(); } catch (e) {}
            };

            window.fancallSetMuted = function (muted) {
              try {
                if (!vobiz || !vobiz.client) return;
                if (muted) vobiz.client.mute(); else vobiz.client.unmute();
              } catch (e) {
                nativeLog('mute failed: ' + e.message);
              }
            };

            function attachRemoteAudio() {
              setTimeout(function () {
                try {
                  const remoteAudio = document.getElementById('fancallRemoteAudio');
                  let stream = null;
                  if (vobiz && vobiz.client && vobiz.client.remoteView) {
                    stream = vobiz.client.remoteView.srcObject;
                  }
                  if (stream && remoteAudio) {
                    remoteAudio.srcObject = stream;
                    remoteAudio.autoplay = true;
                    remoteAudio.playsInline = true;
                    remoteAudio.muted = false;
                    remoteAudio.volume = 1.0;
                    const playPromise = remoteAudio.play && remoteAudio.play();
                    if (playPromise && playPromise.catch) {
                      playPromise.catch(function (e) { nativeLog('remote audio play failed: ' + e.message); });
                    }
                    post('vobizOnRemoteAudioAttached', 'attached');
                    nativeLog('remote audio attached');
                  } else {
                    nativeLog('remote stream not available yet');
                  }
                } catch (e) {
                  nativeLog('attachRemoteAudio error: ' + e.message);
                }
              }, 500);
            }

            function start() {
              if (typeof Vobiz === 'undefined') {
                post('vobizOnLoginFailed', 'Vobiz SDK did not load from CDN');
                return;
              }
              
              vobiz = new Vobiz({
                debug: 'ALL',
                permOnClick: false,
                enableTracking: true,
                closeProtection: false,
                maxAverageBitrate: 48000,
                useDefaultAudioDevice: true,
                useVobizStunServer: true
              });
              
              vobiz.client.on('onLogin', function () {
                nativeLog('onLogin (SIP Registered)');
                post('vobizOnRegistered', 'ok');
              });
              
              vobiz.client.on('onLoginFailed', function (reason) {
                nativeLog('onLoginFailed ' + reason);
                post('vobizOnLoginFailed', reason || 'unknown');
              });
              
              vobiz.client.on('onIncomingCall', function (callerName) {
                nativeLog('onIncomingCall ' + callerName);
                post('vobizOnIncomingCall', callerName || 'unknown');
                setTimeout(window.fancallAnswer, 500);
              });
              
              vobiz.client.on('onCallAnswered', function (info) {
                if (!audioAttached) {
                  audioAttached = true;
                  attachRemoteAudio();
                  setTimeout(attachRemoteAudio, 1500);
                  setTimeout(attachRemoteAudio, 3000);
                }
                nativeLog('onCallAnswered');
                post('vobizOnCallAnswered', 'ok');
              });
              
              vobiz.client.on('onCallFailed', function (info) {
                post('vobizOnCallFailed', (info && info.reason) || 'unknown');
              });
              
              vobiz.client.on('onCallTerminated', function (info) {
                audioAttached = false;
                answerRequested = false;
                post('vobizOnCallTerminated', 'ended');
              });
              
              vobiz.client.on('onConnectionChange', function (event) {
                nativeLog('SIP Connection State: ' + JSON.stringify(event || {}));
              });

              vobiz.client.on('remoteAudioStatus', function (ok) {
                nativeLog('remoteAudioStatus: ' + ok);
                if (ok) attachRemoteAudio();
              });

              nativeLog('SIP Logging in: ' + username);
              vobiz.client.login(username, password);
            }

            if (document.readyState === 'complete') start();
            else window.addEventListener('load', start);
          })();
          </script>
        </body>
        </html>
        """
    }
    
    private func htmlStringWebRTC(roomId: String, token: String, signalingUrl: String, iceServers: [[String: Any]]) -> String {
        let iceServersJson: String
        if let data = try? JSONSerialization.data(withJSONObject: iceServers, options: []),
           let jsonStr = String(data: data, encoding: .utf8) {
            iceServersJson = jsonStr
        } else {
            iceServersJson = "[]"
        }
        
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width,initial-scale=1">
        </head>
        <body>
          <h1 style="font-family:-apple-system,sans-serif; text-align:center; margin-top:20px;">WebRTC Connection</h1>
          <audio id="fancallRemoteAudio" autoplay playsinline></audio>
          
          <script>
          (function () {
            const roomId = "\(roomId)";
            const token = "\(token)";
            const signalingUrl = "\(signalingUrl)";
            const parsedIceServers = \(iceServersJson);
            
            let ws = null;
            let pc = null;
            let localStream = null;
            
            function post(name, payload) {
              try {
                const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name];
                if (handler && handler.postMessage) handler.postMessage(payload);
              } catch (e) {}
            }

            function nativeLog(msg) { post('vobizLog', '[JS WebRTC] ' + String(msg || '')); }
            
            window.fancallHangup = function () {
              nativeLog('Hangup requested.');
              if (ws) {
                try { ws.send(JSON.stringify({ type: 'leave' })); } catch(e) {}
                ws.close();
                ws = null;
              }
              if (pc) {
                pc.close();
                pc = null;
              }
              if (localStream) {
                localStream.getTracks().forEach(track => track.stop());
                localStream = null;
              }
            };
            
            window.fancallLogout = function () {
              window.fancallHangup();
            };
            
            window.fancallSetMuted = function (muted) {
              if (localStream) {
                localStream.getAudioTracks().forEach(track => {
                  track.enabled = !muted;
                });
                nativeLog('Microphone muted state set to: ' + muted);
              }
            };

            async function connect() {
              try {
                nativeLog('Acquiring user media (mic)...');
                localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
                nativeLog('User media acquired successfully.');
                
                // Formulate WebSocket url
                const socketUrl = signalingUrl + (signalingUrl.indexOf('?') !== -1 ? '&' : '?') + 'token=' + token + '&roomId=' + roomId;
                nativeLog('Connecting to signaling server: ' + signalingUrl);
                
                ws = new WebSocket(socketUrl);
                
                ws.onopen = function () {
                  nativeLog('Signaling socket open. Initializing PeerConnection...');
                  setupPeerConnection();
                };
                
                ws.onmessage = async function (event) {
                  try {
                    const data = JSON.parse(event.data);
                    nativeLog('Received signaling message type: ' + data.type);
                    
                    if (data.type === 'offer') {
                      await pc.setRemoteDescription(new RTCSessionDescription(data));
                      nativeLog('Remote offer description set. Creating answer...');
                      const answer = await pc.createAnswer();
                      await pc.setLocalDescription(answer);
                      nativeLog('Local answer set. Sending to remote...');
                      ws.send(JSON.stringify({
                        type: 'answer',
                        sdp: answer.sdp
                      }));
                    } else if (data.type === 'answer') {
                      await pc.setRemoteDescription(new RTCSessionDescription(data));
                      nativeLog('Remote answer description set successfully.');
                    } else if (data.type === 'ice-candidate') {
                      if (data.candidate) {
                        const candidate = new RTCIceCandidate({
                          candidate: data.candidate.candidate || data.candidate,
                          sdpMid: data.candidate.sdpMid,
                          sdpMLineIndex: data.candidate.sdpMLineIndex
                        });
                        await pc.addIceCandidate(candidate);
                        nativeLog('ICE candidate added successfully.');
                      }
                    } else if (data.type === 'joined') {
                      nativeLog('Acknowledge: Joined room. Creating Local Offer...');
                      createLocalOffer();
                    } else if (data.type === 'left' || data.type === 'disconnected') {
                      nativeLog('Signaling reports remote left.');
                      post('vobizOnCallTerminated', 'ended');
                    }
                  } catch (err) {
                    nativeLog('Error processing socket message: ' + err.message);
                  }
                };
                
                ws.onerror = function (err) {
                  nativeLog('Signaling WebSocket error: ' + err.message);
                  post('vobizOnLoginFailed', 'WebSocket connection failed');
                };
                
                ws.onclose = function () {
                  nativeLog('Signaling WebSocket closed.');
                };
                
              } catch (err) {
                nativeLog('Failed to start WebRTC E2E: ' + err.message);
                post('vobizOnLoginFailed', err.message);
              }
            }
            
            function setupPeerConnection() {
              const rtcConfig = {
                iceServers: parsedIceServers.length > 0 ? parsedIceServers : [{ urls: 'stun:stun.l.google.com:19302' }],
                sdpSemantics: 'unified-plan'
              };
              
              pc = new RTCPeerConnection(rtcConfig);
              nativeLog('RTCPeerConnection instantiated.');
              
              localStream.getTracks().forEach(track => {
                pc.addTrack(track, localStream);
              });
              
              pc.onicecandidate = function (event) {
                if (event.candidate && ws && ws.readyState === WebSocket.OPEN) {
                  ws.send(JSON.stringify({
                    type: 'ice-candidate',
                    candidate: {
                      candidate: event.candidate.candidate,
                      sdpMid: event.candidate.sdpMid,
                      sdpMLineIndex: event.candidate.sdpMLineIndex
                    }
                  }));
                }
              };
              
              pc.onconnectionstatechange = function () {
                nativeLog('WebRTC connectionState: ' + pc.connectionState);
                if (pc.connectionState === 'connected') {
                  post('vobizOnCallAnswered', 'ok');
                } else if (pc.connectionState === 'disconnected' || pc.connectionState === 'failed') {
                  post('vobizOnCallTerminated', 'ended');
                }
              };
              
              pc.ontrack = function (event) {
                nativeLog('Received remote media stream track!');
                const remoteAudio = document.getElementById('fancallRemoteAudio');
                if (remoteAudio && event.streams && event.streams[0]) {
                  remoteAudio.srcObject = event.streams[0];
                  post('vobizOnRemoteAudioAttached', 'attached');
                }
              };
              
              // Register WebRTC Ready State
              post('vobizOnRegistered', 'ok');
              
              // Send join message
              setTimeout(() => {
                if (ws && ws.readyState === WebSocket.OPEN) {
                  ws.send(JSON.stringify({ type: 'join' }));
                  nativeLog('Sent join message.');
                }
              }, 500);
            }
            
            async function createLocalOffer() {
              try {
                const offer = await pc.createOffer({ offerToReceiveAudio: true, offerToReceiveVideo: false });
                await pc.setLocalDescription(offer);
                nativeLog('Local offer set. Sending offer via signaling...');
                ws.send(JSON.stringify({
                  type: 'offer',
                  sdp: offer.sdp
                }));
              } catch (err) {
                nativeLog('Failed to create local offer: ' + err.message);
              }
            }
            
            if (document.readyState === 'complete') connect();
            else window.addEventListener('load', connect);
          })();
          </script>
        </body>
        </html>
        """
    }
}

// MARK: - WKScriptMessageHandler

extension VobizCallManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let bodyString = (message.body as? String) ?? ""
        
        switch message.name {
        case "vobizOnRegistered":
            addLog("🟢 SIP/WebRTC registered and ready on client!")
            if let sessionId = activeSessionId {
                notifyBackendMediaReady(sessionId: sessionId)
            }
            
        case "vobizOnLoginFailed":
            addLog("❌ SIP/WebRTC Login Failed: \(bodyString)")
            state = .failed
            cleanup()
            
        case "vobizOnIncomingCall":
            addLog("📥 Incoming Bridge Audio Call from Vobiz")
            
        case "vobizOnCallAnswered":
            addLog("📞 Bridge Audio Stream Connected!")
            state = .connected
            
        case "vobizOnRemoteAudioAttached":
            addLog("🔊 Remote Audio Attached to speaker!")
            
        case "vobizOnCallFailed":
            addLog("❌ Vobiz Call Failed: \(bodyString)")
            state = .failed
            cleanup()
            
        case "vobizOnCallTerminated":
            addLog("📴 Vobiz Call Terminated")
            cleanup()
            
        case "vobizLog":
            print("🌐 [WebRTC Log] \(bodyString)")
            
        default:
            break
        }
    }
}

// MARK: - WKUIDelegate & WKNavigationDelegate

extension VobizCallManager: WKUIDelegate, WKNavigationDelegate {
    @available(iOS 15.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard type == .microphone else {
            decisionHandler(.deny)
            return
        }
        
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                decisionHandler(granted ? .grant : .deny)
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        addLog("❌ WebView failed navigation: \(error.localizedDescription)")
    }
}
