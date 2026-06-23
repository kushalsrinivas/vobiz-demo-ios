import Foundation
import AVFoundation
import WebKit
import WebRTC

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
    
    // Native WebRTC resources
    private var peerConnectionFactory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var signalingClient: WebRTCSignalingClient?
    
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
    
    override init() {
        super.init()
        // Initialize WebRTC SSL on startup
        RTCInitializeSSL()
    }
    
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
        
        // 1. Tell WKWebView to hangup & logout / disconnect (for SIP mode)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.webView?.evaluateJavaScript("window.fancallHangup && window.fancallHangup(); window.fancallLogout && window.fancallLogout();", completionHandler: nil)
        }
        
        // 2. Disconnect native WebRTC signaling & peer connection
        signalingClient?.disconnect()
        signalingClient = nil
        
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        peerConnectionFactory = nil
        
        // 3. Notify backend that session is ended
        if let sessionId = activeSessionId {
            notifyBackendCallEnded(sessionId: sessionId)
        } else {
            cleanup()
        }
    }
    
    func setMuted(_ muted: Bool) {
        self.isMuted = muted
        addLog(muted ? "🎙️ Muting microphone" : "🎙️ Unmuting microphone")
        
        // Mute native audio track if active
        if let localTrack = localAudioTrack {
            localTrack.isEnabled = !muted
            addLog("🎙️ Native WebRTC microphone muted: \(muted)")
        }
        
        // Fallback/parallel for SIP webview
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
            
            // Configure RTCAudioSession for WebRTC
            let rtcSession = RTCAudioSession.sharedInstance()
            rtcSession.useManualAudio = false
            
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
    
    // MARK: - Native WebRTC Registration Method
    
    private func registerWebRTCMode(roomId: String, token: String, signalingUrl: String, iceServers: [[String: Any]]) {
        state = .registeringSIP
        addLog("🚀 Starting Native Swift WebRTC connection...")
        
        guard let url = URL(string: signalingUrl) else {
            addLog("❌ Invalid signaling URL: \(signalingUrl)")
            state = .failed
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Cleanup any existing WKWebView or WebRTC state
            self.cleanupWebView()
            self.signalingClient?.disconnect()
            self.signalingClient = nil
            self.peerConnection?.close()
            self.peerConnection = nil
            self.localAudioTrack = nil
            self.peerConnectionFactory = nil
            
            // Set up WebRTCSignalingClient
            self.signalingClient = WebRTCSignalingClient(url: url, roomId: roomId, token: token)
            
            self.signalingClient?.onConnected = { [weak self] in
                self?.addLog("🌐 Signaling socket connected! Joining room \(roomId)...")
                self?.signalingClient?.sendJoin()
            }
            
            self.signalingClient?.onJoined = { [weak self] in
                guard let self = self else { return }
                self.addLog("🌐 Joined WebRTC room successfully. Setting up PeerConnection and local offer...")
                self.setupPeerConnection(iceServers: iceServers)
                
                // Immediately notify backend that media is ready on the client
                if let sessionId = self.activeSessionId {
                    self.notifyBackendMediaReady(sessionId: sessionId)
                }
                
                self.createLocalOffer()
            }
            
            self.signalingClient?.onReceivedAnswer = { [weak self] answer in
                self?.addLog("🌐 Received SDP Answer from signaling server. Setting remote description...")
                self?.peerConnection?.setRemoteDescription(answer) { error in
                    if let error = error {
                        self?.addLog("❌ Failed to set remote description: \(error.localizedDescription)")
                    } else {
                        self?.addLog("✅ Remote description (SDP Answer) set successfully!")
                    }
                }
            }
            
            self.signalingClient?.onReceivedCandidate = { [weak self] candidate in
                self?.addLog("🌐 Received remote ICE candidate from server. Adding...")
                self?.peerConnection?.add(candidate) { error in
                    if let error = error {
                        self?.addLog("⚠️ Failed to add remote ICE candidate: \(error.localizedDescription)")
                    }
                }
            }
            
            self.signalingClient?.onDisconnected = { [weak self] in
                self?.addLog("🌐 Signaling socket disconnected.")
            }
            
            self.signalingClient?.onError = { [weak self] error in
                self?.addLog("❌ Signaling error: \(error.localizedDescription)")
                self?.state = .failed
                self?.cleanup()
            }
            
            self.signalingClient?.onLog = { [weak self] logMsg in
                self?.addLog(logMsg)
            }
            
            self.signalingClient?.connect()
        }
    }
    
    private func setupPeerConnection(iceServers: [[String: Any]]) {
        peerConnectionFactory = RTCPeerConnectionFactory()
        
        var rtcIceServers: [RTCIceServer] = []
        for server in iceServers {
            if let urls = server["urls"] as? [String] {
                let username = server["username"] as? String
                let credential = server["credential"] as? String
                let iceServer = RTCIceServer(urlStrings: urls, username: username, credential: credential)
                rtcIceServers.append(iceServer)
            }
        }
        
        if rtcIceServers.isEmpty {
            addLog("⚠️ No ICE servers returned by backend. Falling back to Google STUN.")
            rtcIceServers.append(RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]))
        }
        
        let config = RTCConfiguration()
        config.iceServers = rtcIceServers
        config.sdpSemantics = .unifiedPlan
        
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        
        peerConnection = peerConnectionFactory?.peerConnection(with: config, constraints: constraints, delegate: self)
        addLog("✅ Native RTCPeerConnection instantiated.")
        
        // Add local audio track
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = peerConnectionFactory?.audioSource(with: audioConstraints)
        localAudioTrack = peerConnectionFactory?.audioTrack(with: audioSource!, trackId: "audio0")
        
        if let localTrack = localAudioTrack {
            localTrack.isEnabled = !isMuted
            peerConnection?.add(localTrack, streamIds: ["stream0"])
            addLog("✅ Local audio track added to PeerConnection.")
        }
    }
    
    private func createLocalOffer() {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse
            ],
            optionalConstraints: nil
        )
        
        peerConnection?.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self else { return }
            if let error = error {
                self.addLog("❌ Failed to create local offer: \(error.localizedDescription)")
                return
            }
            guard let sdp = sdp else { return }
            
            self.peerConnection?.setLocalDescription(sdp) { error in
                if let error = error {
                    self.addLog("❌ Failed to set local description: \(error.localizedDescription)")
                    return
                }
                self.addLog("✅ Local offer set successfully. Sending to signaling...")
                self.signalingClient?.sendOffer(sdp: sdp.sdp)
            }
        }
    }
    
    // MARK: - Legacy WKWebView Registration Methods (SIP Fallback)
    
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
        
        // Native cleanups
        signalingClient?.disconnect()
        signalingClient = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        peerConnectionFactory = nil
        
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
    
    // MARK: - Legacy Web Page HTML Template (SIP only)
    
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
}

// MARK: - RTCPeerConnectionDelegate

extension VobizCallManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        addLog("WebRTC Signaling State changed: \(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        addLog("Received remote media stream track!")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        addLog("Remote media stream removed.")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        addLog("WebRTC peerConnectionShouldNegotiate - Negotiation needed.")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        var stateStr = ""
        switch newState {
        case .new: stateStr = "new"
        case .checking: stateStr = "checking"
        case .connected: stateStr = "connected"
        case .completed: stateStr = "completed"
        case .failed: stateStr = "failed"
        case .disconnected: stateStr = "disconnected"
        case .closed: stateStr = "closed"
        case .count: stateStr = "count"
        @unknown default: stateStr = "unknown"
        }
        addLog("WebRTC ICE Connection State changed: \(stateStr)")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if newState == .connected || newState == .completed {
                self.addLog("📞 WebRTC E2E connected natively!")
                self.state = .connected
            } else if newState == .failed || newState == .disconnected {
                self.addLog("❌ WebRTC Connection failed or disconnected.")
                self.endCall()
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        var stateStr = ""
        switch newState {
        case .new: stateStr = "new"
        case .gathering: stateStr = "gathering"
        case .complete: stateStr = "complete"
        @unknown default: stateStr = "unknown"
        }
        addLog("WebRTC ICE Gathering State: \(stateStr)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        addLog("Generated local ICE candidate: \(candidate.sdp)")
        signalingClient?.sendCandidate(candidate)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        addLog("Removed ICE candidates.")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        addLog("Data channel opened.")
    }
}

// MARK: - WKScriptMessageHandler

extension VobizCallManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let bodyString = (message.body as? String) ?? ""
        
        switch message.name {
        case "vobizOnRegistered":
            addLog("🟢 SIP registered and ready on client!")
            if let sessionId = activeSessionId {
                notifyBackendMediaReady(sessionId: sessionId)
            }
            
        case "vobizOnLoginFailed":
            addLog("❌ SIP Login Failed: \(bodyString)")
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
            print("🌐 [SIP Log] \(bodyString)")
            
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


// MARK: - WebRTCSignalingClient (Native WebSocket Client)

final class WebRTCSignalingClient: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private let url: URL
    private let roomId: String
    private let token: String
    
    var onConnected: (() -> Void)?
    var onJoined: (() -> Void)?
    var onReceivedOffer: ((RTCSessionDescription) -> Void)?
    var onReceivedAnswer: ((RTCSessionDescription) -> Void)?
    var onReceivedCandidate: ((RTCIceCandidate) -> Void)?
    var onDisconnected: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onLog: ((String) -> Void)?
    
    init(url: URL, roomId: String, token: String) {
        self.url = url
        self.roomId = roomId
        self.token = token
        super.init()
    }
    
    func connect() {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "roomId", value: roomId))
        queryItems.append(URLQueryItem(name: "token", value: token))
        components?.queryItems = queryItems
        
        guard let finalUrl = components?.url else {
            onError?(NSError(domain: "WebRTCSignalingClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }
        
        onLog?("🌐 Connecting to native signaling socket: \(finalUrl.absoluteString)")
        
        // Use a background URLSession configuration for reliable calling
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        webSocket = session.webSocketTask(with: finalUrl)
        webSocket?.resume()
        receiveMessage()
    }
    
    func sendJoin() {
        let message = ["type": "join"]
        sendJson(message)
    }
    
    func sendOffer(sdp: String) {
        let message: [String: Any] = [
            "type": "offer",
            "sdp": sdp
        ]
        sendJson(message)
    }
    
    func sendAnswer(sdp: String) {
        let message: [String: Any] = [
            "type": "answer",
            "sdp": sdp
        ]
        sendJson(message)
    }
    
    func sendCandidate(_ candidate: RTCIceCandidate) {
        let candidatePayload: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": candidate.sdpMLineIndex
        ]
        let message: [String: Any] = [
            "type": "ice-candidate",
            "candidate": candidatePayload
        ]
        sendJson(message)
    }
    
    func disconnect() {
        if webSocket != nil {
            let message = ["type": "leave"]
            sendJson(message)
            webSocket?.cancel(with: .normalClosure, reason: nil)
            webSocket = nil
        }
    }
    
    private func sendJson(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        
        webSocket?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                self?.onLog?("⚠️ Failed to send WS message: \(error.localizedDescription)")
            }
        }
    }
    
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessageText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessageText(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
            case .failure(let error):
                // Do not trigger error if connection was intentionally canceled
                if self.webSocket != nil {
                    self.onError?(error)
                }
            }
        }
    }
    
    private func handleMessageText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        switch type {
        case "joined":
            onJoined?()
        case "offer":
            if let sdpString = json["sdp"] as? String {
                let description = RTCSessionDescription(type: .offer, sdp: sdpString)
                onReceivedOffer?(description)
            } else if let sdpDict = json["sdp"] as? [String: Any], let sdpString = sdpDict["sdp"] as? String {
                let description = RTCSessionDescription(type: .offer, sdp: sdpString)
                onReceivedOffer?(description)
            }
        case "answer":
            if let sdpString = json["sdp"] as? String {
                let description = RTCSessionDescription(type: .answer, sdp: sdpString)
                onReceivedAnswer?(description)
            } else if let sdpDict = json["sdp"] as? [String: Any], let sdpString = sdpDict["sdp"] as? String {
                let description = RTCSessionDescription(type: .answer, sdp: sdpString)
                onReceivedAnswer?(description)
            }
        case "ice-candidate":
            if let candidateData = json["candidate"] as? [String: Any],
               let candidateString = candidateData["candidate"] as? String {
                let sdpMid = candidateData["sdpMid"] as? String
                let sdpMLineIndex = candidateData["sdpMLineIndex"] as? Int32 ?? 0
                let rtcCandidate = RTCIceCandidate(sdp: candidateString, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
                onReceivedCandidate?(rtcCandidate)
            }
        case "left", "disconnected":
            onDisconnected?()
        default:
            break
        }
    }
}

extension WebRTCSignalingClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onConnected?()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onDisconnected?()
    }
}
