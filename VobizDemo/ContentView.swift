import SwiftUI

struct ContentView: View {
    @StateObject private var callManager = VobizCallManager()
    
    @State private var backendURL: String = "https://fancall.kushalneversleeps.com"
    @State private var fanId: String = "2"
    @State private var celebrityId: String = "3"
    @State private var isMuted: Bool = false
    @State private var useSpeaker: Bool = false
    @State private var autoScroll: Bool = true
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Connection Form Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Backend Configuration")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(spacing: 10) {
                        HStack {
                            Text("URL:")
                                .frame(width: 70, alignment: .leading)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("Backend Base URL", text: $backendURL)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .disabled(callManager.state != .idle && callManager.state != .failed)
                        }
                        
                        HStack {
                            Text("Fan ID:")
                                .frame(width: 70, alignment: .leading)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("Fan User ID", text: $fanId)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .disabled(callManager.state != .idle && callManager.state != .failed)
                        }
                        
                        HStack {
                            Text("Celeb ID:")
                                .frame(width: 70, alignment: .leading)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("Celebrity User ID", text: $celebrityId)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .disabled(callManager.state != .idle && callManager.state != .failed)
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                
                // Call Control Card
                VStack(spacing: 16) {
                    // Status Indicator
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor(for: callManager.state))
                            .frame(width: 14, height: 14)
                        
                        Text("Status: \(callManager.state.rawValue)")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                    .padding(.top, 4)
                    
                    // Main Action Button
                    if callManager.state == .idle || callManager.state == .failed {
                        Button(action: {
                            callManager.startCall(backendURL: backendURL, fanId: fanId, celebrityId: celebrityId)
                        }) {
                            HStack {
                                Image(systemName: "phone.fill")
                                Text("Initiate Vobiz Call")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    } else {
                        Button(action: {
                            callManager.endCall()
                        }) {
                            HStack {
                                Image(systemName: "phone.down.fill")
                                Text(callManager.state == .ending ? "Hanging Up..." : "Hang Up Call")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .disabled(callManager.state == .ending)
                        }
                    }
                    
                    // Auxiliary controls (Mute / Speaker)
                    if callManager.state == .connected || callManager.state == .ringingCelebrity {
                        HStack(spacing: 20) {
                            Button(action: {
                                isMuted.toggle()
                                callManager.setMuted(isMuted)
                            }) {
                                HStack {
                                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                                    Text(isMuted ? "Unmute" : "Mute")
                                }
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(isMuted ? Color.orange.opacity(0.2) : Color.blue.opacity(0.1))
                                .foregroundColor(isMuted ? .orange : .blue)
                                .cornerRadius(8)
                            }
                            
                            Button(action: {
                                useSpeaker.toggle()
                                callManager.toggleSpeaker(useSpeaker)
                            }) {
                                HStack {
                                    Image(systemName: useSpeaker ? "speaker.wave.3.fill" : "speaker.fill")
                                    Text(useSpeaker ? "Earpiece" : "Speaker")
                                }
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(useSpeaker ? Color.purple.opacity(0.2) : Color.blue.opacity(0.1))
                                .foregroundColor(useSpeaker ? .purple : .blue)
                                .cornerRadius(8)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                
                // Console Logs Header
                HStack {
                    Text("Connection Console")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Button(action: {
                        callManager.logs.removeAll()
                    }) {
                        Text("Clear Logs")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 4)
                
                // Real-time Scrolling Log Viewer
                ScrollViewReader { scrollViewProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if callManager.logs.isEmpty {
                                Text("Ready to call. Connection logs will stream here in real-time.")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 12)
                            } else {
                                ForEach(0..<callManager.logs.count, id: \.self) { idx in
                                    Text(callManager.logs[idx])
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundColor(logColor(for: callManager.logs[idx]))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(idx)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .background(Color.black)
                    .cornerRadius(8)
                    .onChange(of: callManager.logs.count) { _ in
                        if autoScroll, !callManager.logs.isEmpty {
                            withAnimation {
                                scrollViewProxy.scrollTo(callManager.logs.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding()
            .navigationTitle("Vobiz Call Demo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func statusColor(for state: CallState) -> Color {
        switch state {
        case .idle: return .gray
        case .creatingSession, .registeringSIP: return .orange
        case .registeredSIP, .ringingCelebrity: return .yellow
        case .connected: return .green
        case .ending: return .red
        case .failed: return .red
        }
    }
    
    private func logColor(for log: String) -> Color {
        if log.contains("❌") || log.contains("failed") || log.contains("Failed") {
            return .red
        } else if log.contains("✅") || log.contains("Successfully") {
            return .green
        } else if log.contains("⚠️") {
            return .yellow
        } else if log.contains("State changed") {
            return .cyan
        } else {
            return .white
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
