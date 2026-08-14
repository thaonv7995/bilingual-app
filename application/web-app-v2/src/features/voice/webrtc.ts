/**
 * OpenAI Realtime voice session over WebRTC — ported from v1
 * (app.js:2444-2762). Framework-agnostic; React drives it through `handlers`.
 *
 * The data-channel handler reads mic-mute and executes tools via `handlers`
 * (which the useVoice hook backs with refs), so it always sees live reader
 * state — fixing v1's stale-closure mic re-enable and stale-page tools
 * (review #6/#7). On a failed connect, the mic stream is stopped (no leak).
 */
import { apiFetch } from '@/lib/api-client';
import type { ToolResult } from './tools';
import { WEB_TOOL_DEFINITIONS } from './tools';

export type RealtimeState = 'idle' | 'connecting' | 'live' | 'error';
export type SpeakingState = 'idle' | 'connecting' | 'listening' | 'user-speaking' | 'ai-speaking';
export interface ToolCallUI {
  name: string;
  status: 'executing' | 'success' | 'error';
  text: string;
  color?: string;
  error?: string;
}

export interface VoiceConfig {
  model: string;
  voice: string;
  instructions: string;
}

export interface VoiceHandlers {
  onState: (s: RealtimeState) => void;
  onSpeakingState: (s: SpeakingState) => void;
  onCaptionDelta: (delta: string) => void;
  onCaptionSet: (text: string) => void;
  onUserTranscript: (text: string) => void;
  onToolCall: (tc: ToolCallUI | null) => void;
  onError: (msg: string) => void;
  getMicMuted: () => boolean;
  executeTool: (name: string, args: Record<string, unknown>) => Promise<ToolResult>;
}

export interface VoiceSession {
  stop: () => void;
  toggleMic: () => boolean; // returns the new muted state
  isMicMuted: () => boolean;
  sendPageContext: (page: number, pageText: string) => void;
}

export async function startVoiceSession(
  config: VoiceConfig,
  handlers: VoiceHandlers,
): Promise<VoiceSession> {
  let micMuted = false;
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  const setTracks = (enabled: boolean) => stream.getAudioTracks().forEach((t) => (t.enabled = enabled));

  let peer: RTCPeerConnection | null = null;
  let audioEl: HTMLAudioElement | null = null;

  try {
    // 1. Ephemeral key via the backend proxy, which attaches the server-held
    //    per-user realtime key (the browser never sends it).
    const sessionRes = await apiFetch('/api/chat/realtime/session', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        session: { type: 'realtime', model: config.model, instructions: config.instructions },
      }),
    });
    if (!sessionRes.ok) {
      const detail = await sessionRes.json().catch(() => ({}));
      throw new Error(detail?.detail || `Không tạo được phiên (${sessionRes.status})`);
    }
    const sessionData = await sessionRes.json();
    const ephemeralKey = sessionData.client_secret?.value || sessionData.value;
    if (!ephemeralKey) throw new Error('OpenAI không trả về ephemeral key.');

    // 2. Peer connection + remote audio playback.
    const pc = new RTCPeerConnection();
    peer = pc;
    stream.getTracks().forEach((track) => pc.addTrack(track, stream));
    const remoteStream = new MediaStream();
    pc.ontrack = (e) => remoteStream.addTrack(e.track);
    const audio = document.createElement('audio');
    audioEl = audio;
    audio.autoplay = true;
    audio.srcObject = remoteStream;
    document.body.appendChild(audio);

    // 3. Data channel.
    const dc = pc.createDataChannel('oai-events');

    dc.addEventListener('open', () => {
      handlers.onState('live');
      handlers.onSpeakingState('listening');
      dc.send(
        JSON.stringify({
          type: 'session.update',
          session: {
            modalities: ['text', 'audio'],
            voice: config.voice,
            input_audio_transcription: { model: 'whisper-1' },
            turn_detection: { type: 'server_vad', threshold: 0.5, prefix_padding_ms: 400, silence_duration_ms: 1200 },
            tools: WEB_TOOL_DEFINITIONS.map((t) => ({ type: 'function', name: t.name, description: t.description, parameters: t.parameters })),
            tool_choice: 'auto',
          },
        }),
      );
      dc.send(JSON.stringify({ type: 'response.create' }));
    });

    dc.addEventListener('message', async (e) => {
      let evt: {
        type: string;
        delta?: string;
        transcript?: string;
        error?: { message?: string };
        response?: { output?: Array<{ type: string; name: string; arguments: string; call_id: string }> };
      };
      try {
        evt = JSON.parse(e.data);
      } catch {
        return;
      }

      if (evt.type === 'error') return handlers.onError(evt.error?.message || 'Lỗi kết nối Realtime');
      if (evt.type === 'response.created') {
        handlers.onSpeakingState('ai-speaking');
        handlers.onCaptionSet('');
        setTracks(false); // mute mic while the AI speaks
        return;
      }
      if (evt.type === 'response.audio_transcript.delta') {
        handlers.onSpeakingState('ai-speaking');
        return handlers.onCaptionDelta(evt.delta || '');
      }
      if (evt.type === 'response.audio_transcript.done') {
        handlers.onCaptionSet(evt.transcript || '');
        handlers.onSpeakingState('listening');
        if (!handlers.getMicMuted()) setTracks(true); // live read — fixes stale unmute
        return;
      }
      if (evt.type === 'conversation.item.input_audio_transcription.completed') {
        handlers.onUserTranscript(evt.transcript || '');
        return handlers.onSpeakingState('listening');
      }
      if (evt.type === 'input_audio_buffer.speech_started') {
        handlers.onCaptionSet('...');
        handlers.onSpeakingState('user-speaking');
        audio.pause();
        audio.currentTime = 0;
        audio.play().catch(() => {});
        return;
      }
      if (evt.type === 'response.done') {
        handlers.onSpeakingState('listening');
        if (!handlers.getMicMuted()) setTracks(true);
        for (const item of evt.response?.output ?? []) {
          if (item.type !== 'function_call') continue;
          let args: Record<string, unknown> = {};
          try {
            args = JSON.parse(item.arguments);
          } catch {
            /* keep empty */
          }
          const label = String(args.text ?? args.word ?? args.page ?? '');
          handlers.onToolCall({ name: item.name, status: 'executing', text: label, color: args.color as string });
          const result = await handlers.executeTool(item.name, args);
          handlers.onToolCall({
            name: item.name,
            status: result.success ? 'success' : 'error',
            text: label,
            color: args.color as string,
            error: result.error as string,
          });
          setTimeout(() => handlers.onToolCall(null), 4000);
          dc.send(
            JSON.stringify({
              type: 'conversation.item.create',
              item: { type: 'function_call_output', call_id: item.call_id, output: JSON.stringify(result) },
            }),
          );
          dc.send(JSON.stringify({ type: 'response.create' }));
        }
      }
    });

    // 4. SDP handshake with OpenAI's realtime calls endpoint.
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    const sdpRes = await fetch('https://api.openai.com/v1/realtime/calls', {
      method: 'POST',
      headers: { Authorization: `Bearer ${ephemeralKey}`, 'Content-Type': 'application/sdp' },
      body: offer.sdp,
    });
    if (!sdpRes.ok) {
      const details = await sdpRes.text().catch(() => '');
      throw new Error(`SDP exchange failed (${sdpRes.status}). ${details.slice(0, 200)}`);
    }
    await pc.setRemoteDescription({ type: 'answer', sdp: await sdpRes.text() });

    return {
      stop: () => {
        pc.close();
        stream.getTracks().forEach((t) => t.stop());
        audio.remove();
      },
      toggleMic: () => {
        micMuted = !micMuted;
        setTracks(!micMuted);
        return micMuted;
      },
      isMicMuted: () => micMuted,
      sendPageContext: (page, pageText) => {
        if (dc.readyState !== 'open' || !pageText) return;
        dc.send(
          JSON.stringify({
            type: 'conversation.item.create',
            item: {
              type: 'message',
              role: 'system',
              content: [{ type: 'input_text', text: `[PAGE UPDATE] User is now on page ${page}.\n${pageText}` }],
            },
          }),
        );
      },
    };
  } catch (err) {
    peer?.close();
    stream.getTracks().forEach((t) => t.stop());
    audioEl?.remove();
    throw err;
  }
}
