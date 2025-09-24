#!/usr/bin/env node

/**
 * Build script to create browser-utils.global.js bundle
 * This script bundles the browser utility classes into a single file that can be injected into browser context
 */

const fs = require('fs');
const path = require('path');

// This script creates a standalone browser bundle without requiring compiled files
// The browser utilities are embedded directly in this script

// Create the browser bundle content
const browserBundleContent = `
// Browser utilities bundle for Vexa Bot
// This file is injected into browser context via page.addScriptTag()

(function() {
  'use strict';
  
  // Browser UUID generation
  function generateBrowserUUID() {
    if (typeof crypto !== "undefined" && crypto.randomUUID) {
      return crypto.randomUUID();
    } else {
      return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(
        /[xy]/g,
        function (c) {
          var r = (Math.random() * 16) | 0,
            v = c == "x" ? r : (r & 0x3) | 0x8;
          return v.toString(16);
        }
      );
    }
  }

  // Browser Audio Service
  class BrowserAudioService {
    constructor(config) {
      this.config = config;
      this.processor = null;
      this.audioContext = null;
      this.destinationNode = null;
    }

    async findMediaElements(retries = 5, delay = 2000) {
      for (let i = 0; i < retries; i++) {
        const mediaElements = Array.from(
          document.querySelectorAll("audio, video")
        ).filter((el) => 
          !el.paused && 
          el.srcObject instanceof MediaStream && 
          el.srcObject.getAudioTracks().length > 0
        );

        if (mediaElements.length > 0) {
          window.logBot && window.logBot(\`Found \${mediaElements.length} active media elements with audio tracks after \${i + 1} attempt(s).\`);
          return mediaElements;
        }
        window.logBot && window.logBot(\`[Audio] No active media elements found. Retrying in \${delay}ms... (Attempt \${i + 2}/\${retries})\`);
        await new Promise(resolve => setTimeout(resolve, delay));
      }
      return [];
    }

    async createCombinedAudioStream(mediaElements) {
      if (mediaElements.length === 0) {
        throw new Error("No media elements provided for audio stream creation");
      }

      window.logBot && window.logBot(\`Found \${mediaElements.length} active media elements.\`);
      if (!this.audioContext) {
        this.audioContext = new AudioContext();
      }
      if (!this.destinationNode) {
        this.destinationNode = this.audioContext.createMediaStreamDestination();
      }
      let sourcesConnected = 0;

      // Connect all media elements to the destination node
      mediaElements.forEach((element, index) => {
        try {
          // Ensure element is actually audible
          if (typeof element.muted === "boolean") element.muted = false;
          if (typeof element.volume === "number") element.volume = 1.0;
          if (typeof element.play === "function") {
            element.play().catch(() => {});
          }

          const elementStream =
            element.srcObject ||
            (element.captureStream && element.captureStream()) ||
            (element.mozCaptureStream && element.mozCaptureStream());

          // Debug audio tracks and unmute them
          if (elementStream instanceof MediaStream) {
            const audioTracks = elementStream.getAudioTracks();
            window.logBot && window.logBot(\`Element \${index + 1}: Found \${audioTracks.length} audio tracks\`);
            audioTracks.forEach((track, trackIndex) => {
              window.logBot && window.logBot(\`  Track \${trackIndex}: enabled=\${track.enabled}, muted=\${track.muted}, label=\${track.label}\`);
              
              // Unmute muted audio tracks
              if (track.muted) {
                track.enabled = true;
                // Force unmute by setting muted to false
                try {
                  track.muted = false;
                  window.logBot && window.logBot(\`  Unmuted track \${trackIndex} (enabled=\${track.enabled}, muted=\${track.muted})\`);
                } catch (e) {
                  const message = e instanceof Error ? e.message : String(e);
                  window.logBot && window.logBot(\`  Could not unmute track \${trackIndex}: \${message}\`);
                }
              }
            });
          }

          if (
            elementStream instanceof MediaStream &&
            elementStream.getAudioTracks().length > 0
          ) {
            // Connect regardless of the read-only muted flag; WebAudio can still pull samples
            const sourceNode = this.audioContext.createMediaStreamSource(elementStream);
            sourceNode.connect(this.destinationNode);
            sourcesConnected++;
            window.logBot && window.logBot(\`Connected audio stream from element \${index + 1}/\${mediaElements.length}. Tracks=\${elementStream.getAudioTracks().length}\`);
          } else {
            window.logBot && window.logBot(\`Skipping element \${index + 1}: No audio tracks found\`);
          }
        } catch (error) {
          window.logBot && window.logBot(\`Could not connect element \${index + 1}: \${error.message}\`);
        }
      });

      if (sourcesConnected === 0) {
        throw new Error("Could not connect any audio streams. Check media permissions.");
      }

      window.logBot && window.logBot(\`Successfully combined \${sourcesConnected} audio streams.\`);
      return this.destinationNode.stream;
    }

    async initializeAudioProcessor(combinedStream) {
      // Reuse existing context if available
      if (!this.audioContext) {
        this.audioContext = new AudioContext();
      }
      if (!this.destinationNode) {
        this.destinationNode = this.audioContext.createMediaStreamDestination();
      }

      const mediaStream = this.audioContext.createMediaStreamSource(combinedStream);
      const recorder = this.audioContext.createScriptProcessor(
        this.config.bufferSize,
        this.config.inputChannels,
        this.config.outputChannels
      );
      const gainNode = this.audioContext.createGain();
      gainNode.gain.value = 0; // Silent playback

      // Connect the audio processing pipeline
      mediaStream.connect(recorder);
      recorder.connect(gainNode);
      gainNode.connect(this.audioContext.destination);

      this.processor = {
        audioContext: this.audioContext,
        destinationNode: this.destinationNode,
        recorder,
        mediaStream,
        gainNode,
        sessionAudioStartTimeMs: null
      };

      try { await this.audioContext.resume(); } catch {}
      window.logBot && window.logBot("Audio processing pipeline connected and ready.");
      return this.processor;
    }

    setupAudioDataProcessor(onAudioData) {
      if (!this.processor) {
        throw new Error("Audio processor not initialized");
      }

      this.processor.recorder.onaudioprocess = async (event) => {
        // Set session start time on first audio chunk
        if (this.processor.sessionAudioStartTimeMs === null) {
          this.processor.sessionAudioStartTimeMs = Date.now();
          window.logBot && window.logBot(\`[Audio] Session audio start time set: \${this.processor.sessionAudioStartTimeMs}\`);
        }

        const inputData = event.inputBuffer.getChannelData(0);
        const resampledData = this.resampleAudioData(inputData, this.processor.audioContext.sampleRate);
        
        onAudioData(resampledData, this.processor.sessionAudioStartTimeMs);
      };
    }

    resampleAudioData(inputData, sourceSampleRate) {
      const targetLength = Math.round(
        inputData.length * (this.config.targetSampleRate / sourceSampleRate)
      );
      const resampledData = new Float32Array(targetLength);
      const springFactor = (inputData.length - 1) / (targetLength - 1);
      
      resampledData[0] = inputData[0];
      resampledData[targetLength - 1] = inputData[inputData.length - 1];
      
      for (let i = 1; i < targetLength - 1; i++) {
        const index = i * springFactor;
        const leftIndex = Math.floor(index);
        const rightIndex = Math.ceil(index);
        const fraction = index - leftIndex;
        resampledData[i] =
          inputData[leftIndex] +
          (inputData[rightIndex] - inputData[leftIndex]) * fraction;
      }
      
      return resampledData;
    }

    getSessionAudioStartTime() {
      return this.processor?.sessionAudioStartTimeMs || null;
    }

    disconnect() {
      if (this.processor) {
        try {
          this.processor.recorder.disconnect();
          this.processor.mediaStream.disconnect();
          this.processor.gainNode.disconnect();
          this.processor.audioContext.close();
          window.logBot && window.logBot("Audio processing pipeline disconnected.");
        } catch (error) {
          window.logBot && window.logBot(\`Error disconnecting audio pipeline: \${error.message}\`);
        }
        this.processor = null;
      }
    }
  }

  // Browser WhisperLive Service
  class BrowserWhisperLiveService {
    constructor(config, stubbornMode = false) {
      this.whisperLiveUrl = config.whisperLiveUrl;
      this.socket = null;
      this.isServerReady = false;
      this.botConfigData = null;
      this.currentUid = null;
      this.onMessageCallback = null;
      this.onErrorCallback = null;
      this.onCloseCallback = null;
      this.reconnectInterval = null;
      this.retryCount = 0;
      this.maxRetries = Number.MAX_SAFE_INTEGER; // TRULY NEVER GIVE UP!
      this.retryDelayMs = 2000;
      this.stubbornMode = stubbornMode;
    }

    async connectToWhisperLive(botConfigData, onMessage, onError, onClose) {
      // Store callbacks for reconnection
      this.botConfigData = botConfigData;
      this.onMessageCallback = onMessage;
      this.onErrorCallback = onError;
      this.onCloseCallback = onClose;

      if (this.stubbornMode) {
        return this.attemptConnection();
      } else {
        return this.simpleConnection();
      }
    }

    async simpleConnection() {
      try {
        this.socket = new WebSocket(this.whisperLiveUrl);
        
        this.socket.onopen = () => {
          this.currentUid = generateBrowserUUID();
          window.logBot && window.logBot(\`[Failover] WebSocket connection opened successfully to \${this.whisperLiveUrl}. New UID: \${this.currentUid}. Lang: \${this.botConfigData.language}, Task: \${this.botConfigData.task}\`);
          
          const configPayload = {
            uid: this.currentUid,
            language: this.botConfigData.language || null,
            task: this.botConfigData.task || "transcribe",
            model: null,
            use_vad: false,
            platform: this.botConfigData.platform,
            token: this.botConfigData.token,
            meeting_id: this.botConfigData.nativeMeetingId,
            meeting_url: this.botConfigData.meetingUrl || null,
          };

          window.logBot && window.logBot(\`Sending initial config message: \${JSON.stringify(configPayload)}\`);
          this.socket.send(JSON.stringify(configPayload));
        };

        this.socket.onmessage = (event) => {
          const data = JSON.parse(event.data);
          if (this.onMessageCallback) {
            this.onMessageCallback(data);
          }
        };

        this.socket.onerror = this.onErrorCallback;
        this.socket.onclose = this.onCloseCallback;

        return this.socket;
      } catch (error) {
        window.logBot && window.logBot(\`[WhisperLive] Connection error: \${error.message}\`);
        return null;
      }
    }

    async attemptConnection() {
      try {
        window.logBot && window.logBot(\`[STUBBORN] 🚀 Connecting to WhisperLive with NEVER-GIVE-UP reconnection: \${this.whisperLiveUrl} (attempt \${this.retryCount + 1})\`);
        
        this.socket = new WebSocket(this.whisperLiveUrl);
        
        this.socket.onopen = (event) => {
          window.logBot && window.logBot(\`[STUBBORN] ✅ WebSocket CONNECTED to \${this.whisperLiveUrl}! Retry count reset from \${this.retryCount}.\`);
          this.retryCount = 0; // Reset on successful connection
          this.clearReconnectInterval(); // Stop any ongoing reconnection attempts
          this.isServerReady = false; // Will be set to true when SERVER_READY received
          
          this.currentUid = generateBrowserUUID();
          const configPayload = {
            uid: this.currentUid,
            language: this.botConfigData.language || null,
            task: this.botConfigData.task || "transcribe",
            model: null,
            use_vad: false,
            platform: this.botConfigData.platform,
            token: this.botConfigData.token,
            meeting_id: this.botConfigData.nativeMeetingId,
            meeting_url: this.botConfigData.meetingUrl || null,
          };

          window.logBot && window.logBot(\`Sending initial config message: \${JSON.stringify(configPayload)}\`);
          if (this.socket) {
            this.socket.send(JSON.stringify(configPayload));
          }
        };

        this.socket.onmessage = (event) => {
          const data = JSON.parse(event.data);
          if (this.onMessageCallback) {
            this.onMessageCallback(data);
          }
        };

        this.socket.onerror = (event) => {
          window.logBot && window.logBot(\`[STUBBORN] ❌ WebSocket ERROR. Will start stubborn reconnection...\`);
          if (this.onErrorCallback) {
            this.onErrorCallback(event);
          }
          this.startStubbornReconnection();
        };

        this.socket.onclose = (event) => {
          window.logBot && window.logBot(\`[STUBBORN] ❌ WebSocket CLOSED. Code: \${event.code}, Reason: "\${event.reason}". WILL RECONNECT NO MATTER WHAT!\`);
          this.isServerReady = false;
          this.socket = null;
          if (this.onCloseCallback) {
            this.onCloseCallback(event);
          }
          this.startStubbornReconnection();
        };

        return this.socket;
      } catch (error) {
        window.logBot && window.logBot(\`[STUBBORN] ❌ Connection creation error: \${error.message}. WILL KEEP TRYING!\`);
        this.startStubbornReconnection();
        return null;
      }
    }

    startStubbornReconnection() {
      if (this.reconnectInterval) {
        return; // Already reconnecting
      }

      // Exponential backoff with max delay of 10 seconds
      const delay = Math.min(this.retryDelayMs * Math.pow(1.5, Math.min(this.retryCount, 10)), 10000);
      
      window.logBot && window.logBot(\`[STUBBORN] 🔄 Starting STUBBORN reconnection in \${delay}ms (attempt \${this.retryCount + 1}/∞ - WE NEVER GIVE UP!)...\`);
      
      this.reconnectInterval = setTimeout(async () => {
        this.reconnectInterval = null;
        this.retryCount++;
        
        if (this.retryCount >= 1000) { // Reset counter every 1000 attempts to prevent overflow
          window.logBot && window.logBot(\`[STUBBORN] 🔄 Resetting retry counter after 1000 attempts. WE WILL NEVER GIVE UP! EVER!\`);
          this.retryCount = 0; // Reset and keep going - NEVER GIVE UP!
        }
        
        if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
          window.logBot && window.logBot(\`[STUBBORN] 🔄 Attempting reconnection (retry \${this.retryCount})...\`);
          await this.attemptConnection();
        } else {
          window.logBot && window.logBot(\`[STUBBORN] ✅ Connection already restored!\`);
        }
      }, delay);
    }

    clearReconnectInterval() {
      if (this.reconnectInterval) {
        clearTimeout(this.reconnectInterval);
        this.reconnectInterval = null;
      }
    }

    sendAudioData(audioData) {
      if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
        return false;
      }

      try {
        // Send Float32Array directly as WhisperLive expects
        this.socket.send(audioData);
        return true;
      } catch (error) {
        window.logBot && window.logBot(\`[WhisperLive] Error sending audio data: \${error.message}\`);
        return false;
      }
    }

    sendAudioChunkMetadata(chunkLength, sampleRate) {
      if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
        return false;
      }

      const meta = {
        type: "audio_chunk_metadata",
        payload: {
          length: chunkLength,
          sample_rate: sampleRate,
          client_timestamp_ms: Date.now(),
        },
      };

      try {
        this.socket.send(JSON.stringify(meta));
        return true;
      } catch (error) {
        window.logBot && window.logBot(\`[WhisperLive] Error sending audio metadata: \${error.message}\`);
        return false;
      }
    }

    sendSpeakerEvent(eventType, participantName, participantId, relativeTimestampMs, botConfigData) {
      if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
        return false;
      }

      const speakerEventMessage = {
        type: "speaker_activity",
        payload: {
          event_type: eventType,
          participant_name: participantName,
          participant_id_meet: participantId,
          relative_client_timestamp_ms: relativeTimestampMs,
          uid: this.currentUid,
          token: botConfigData.token,
          platform: botConfigData.platform,
          meeting_id: botConfigData.nativeMeetingId,
          meeting_url: botConfigData.meetingUrl
        }
      };

      try {
        this.socket.send(JSON.stringify(speakerEventMessage));
        return true;
      } catch (error) {
        window.logBot && window.logBot(\`[WhisperLive] Error sending speaker event: \${error.message}\`);
        return false;
      }
    }

    getCurrentUid() {
      return this.currentUid;
    }

    sendSessionControl(event, botConfigData) {
      if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
        return false;
      }

      const sessionControlMessage = {
        type: "session_control",
        payload: {
          event: event,
          uid: generateBrowserUUID(),
          client_timestamp_ms: Date.now(),
          token: botConfigData.token,
          platform: botConfigData.platform,
          meeting_id: botConfigData.nativeMeetingId
        }
      };

      try {
        this.socket.send(JSON.stringify(sessionControlMessage));
        return true;
      } catch (error) {
        window.logBot && window.logBot(\`[WhisperLive] Error sending session control: \${error.message}\`);
        return false;
      }
    }

    isReady() {
      return this.isServerReady;
    }

    setServerReady(ready) {
      this.isServerReady = ready;
    }

    isOpen() {
      return this.socket?.readyState === WebSocket.OPEN;
    }

    close() {
      window.logBot && window.logBot(\`[STUBBORN] 🛑 Closing WebSocket and stopping reconnection...\`);
      this.clearReconnectInterval();
      if (this.socket) {
        this.socket.close();
        this.socket = null;
      }
    }
  }

  // Expose utilities on window object
  window.VexaBrowserUtils = {
    BrowserAudioService,
    BrowserWhisperLiveService,
    generateBrowserUUID
  };

  // Also expose performLeaveAction for platform-specific leave UX
  window.performLeaveAction = function(reason) {
    window.logBot && window.logBot(\`Platform-specific leave action triggered: \${reason}\`);
    // This can be overridden by platform-specific implementations
  };

  console.log('Vexa Browser Utils loaded successfully');
})();
`;

// Ensure dist directory exists
const distDir = path.join(__dirname, 'dist');
if (!fs.existsSync(distDir)) {
  fs.mkdirSync(distDir, { recursive: true });
}

// Write the browser bundle
const outputPath = path.join(distDir, 'browser-utils.global.js');
fs.writeFileSync(outputPath, browserBundleContent);

console.log(`✅ Browser utilities bundle created: ${outputPath}`);
console.log('📦 Bundle includes:');
console.log('  - BrowserAudioService');
console.log('  - BrowserWhisperLiveService');
console.log('  - generateBrowserUUID');
console.log('  - window.VexaBrowserUtils');
console.log('  - window.performLeaveAction');
