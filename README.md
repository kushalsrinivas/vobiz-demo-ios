# Vobiz iOS Demo Application

This is a lightweight, fully functional, and self-contained iOS application built using SwiftUI and Swift. It connects to the Fancall Voice backend to initiate, register, and bridge normal phone calls using the **VoBiz PSTN SIP Bridge** (and not Agora).

---

## 🏗️ Project Architecture

Instead of compiling complex native SIP libraries like Linphone, this demo app implements the **VoBiz WebRTC-to-SIP Bridge client** natively via a hidden `WKWebView`. It is fully self-contained and loads the official VoBiz WebRTC SDK dynamically from unpkg CDN.

### Key Components

1. **`VobizDemoApp.swift`**: The main entry point of our SwiftUI application.
2. **`ContentView.swift`**: A beautiful single-screen UI containing:
   - **Backend Configuration Form**: Text fields to specify the backend URL, the Fan User ID, and the Celebrity User ID.
   - **Call Controls**: A prominent **Call / Hang Up** button, with auxiliary controls for **Mute** and **Speakerphone** that activate once connected.
   - **Connection Console**: A scrollable terminal window that streams real-time logs, API requests, and WebRTC registration states.
3. **`VobizCallManager.swift`**: The core calling manager (conforming to `WKScriptMessageHandler` & `WKUIDelegate`):
   - Requests native microphone permissions dynamically.
   - Sets the native `AVAudioSession` category to `.playAndRecord` and mode `.voiceChat` (optimized for VoIP calls).
   - POSTs to the backend `/api/v3/voice/sessions` endpoint to allocate a temporary SIP endpoint.
   - Instantiates a hidden `WKWebView` and loads the WebRTC container to register with the VoBiz SIP registrar.
   - Notifies the backend `/media-ready` when SIP registration is active.
   - Receives connection and termination event handlers from WebRTC to adjust the call state.
   - Sends the `/end` POST request to hang up.

---

## 🚀 Step-by-Step E2E Testing Guide

To test the calling flow, follow this step-by-step setup guide.

### Step 1: Backend Domain

The application is pre-configured to use your active public backend server: **`https://fancall.kushalneversleeps.com`**.

This means you do not need to configure any local database, Redis, or start any local Node.js servers or tunnels! The demo app connects directly to the production-configured cloud backend, matching the same URL that the production Fancall app uses.

### Step 2: Open and Run the iOS Demo App

1. Open the generated project in Xcode:
   ```bash
   open /Users/kushalsrinivas/apps/fancall/vobiz-demo-ios/VobizDemo.xcodeproj
   ```
2. Build and run the app on a **real iOS device** (to test real microphone and speaker audio, though it also runs on simulators!).
3. Grant microphone permission when prompted.

### Step 3: Place a Test Call!

1. In the **Backend Configuration** form of the app, set:
   - **URL**: `https://fancall.kushalneversleeps.com`
   - **Fan ID**: `900001` (or your active test fan ID)
   - **Celeb ID**: `900002` (or your active test celebrity ID)
2. Tap **Initiate Vobiz Call**.
3. Watch the **Connection Console** print real-time events:
   - `[Creating Session]` -> Calls `/voice/sessions`
   - `[Registering SIP Client]` -> Instantiates WebRTC SDK inside WebView and registers the SIP client
   - `[SIP Registered (Media Ready)]` -> SIP registration completes; notifies `/media-ready`
   - `[Celebrity Ringing]` -> Backend receives media-ready and dials the celebrity's physical cellular phone.
4. The celebrity's cellular phone will start ringing!
5. When the celebrity answers, the status will change to **Connected**, and you can speak to each other like a normal call!
6. Tap **Hang Up Call** to disconnect both legs.

---

## 🛠️ Code Reference

Here is the exact code showing how the HTML container is set up in Swift to execute the VoBiz SDK registration:

```swift
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
  post('vobizOnRegistered', 'ok');
});

vobiz.client.on('onIncomingCall', function (callerName) {
  // Auto-answer incoming bridge leg call
  setTimeout(window.fancallAnswer, 500);
});
```
# vobiz-demo-ios
