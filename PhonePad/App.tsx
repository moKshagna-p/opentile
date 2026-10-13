import React, { useEffect, useRef, useState } from 'react';
import { AppState, Pressable, StyleSheet, Text, View, type GestureResponderEvent } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { CameraView, useCameraPermissions } from 'expo-camera';
import * as Haptics from 'expo-haptics';
import * as SecureStore from 'expo-secure-store';
import { PadConnection } from './src/PadConnection';
import { normalizeTouches, parsePairing } from './src/protocol';
import type { Pairing, Touch } from './src/protocol';

const storageKey = 'opentile-pad-pairing';

function Pad() {
  const [connected, setConnected] = useState(false);
  const [message, setMessage] = useState('Your Mac, within reach.');
  const [hint, setHint] = useState('Pinch, hold, then move together to place a tile.');
  const [scanning, setScanning] = useState(false);
  const [pairing, setPairing] = useState<Pairing | null>(null);
  const [resize, setResize] = useState(false);
  const [permission, requestPermission] = useCameraPermissions();
  const connection = useRef<PadConnection | null>(null);
  const dimensions = useRef({ width: 1, height: 1 });
  const touches = useRef<Touch[]>([]);
  const mode = useRef(false);
  const blocked = useRef(false);
  const frame = useRef<number | null>(null);
  const scanLocked = useRef(false);
  const alive = useRef(true);

  function stopFrames() {
    if (frame.current !== null) cancelAnimationFrame(frame.current);
    frame.current = null;
    touches.current = [];
  }
  function disconnect(reason: string) {
    stopFrames();
    blocked.current = true;
    connection.current?.close(reason);
    connection.current = null;
  }
  useEffect(() => {
    alive.current = true;
    void SecureStore.getItemAsync(storageKey).then(saved => {
      if (saved && alive.current) { try { setPairing(parsePairing(saved)); } catch { void SecureStore.deleteItemAsync(storageKey); } }
    }).catch(() => {});
    const subscription = AppState.addEventListener('change', state => {
      if (state !== 'active') disconnect('Paused. Reconnect when you return.');
    });
    return () => { alive.current = false; disconnect('Disconnected'); subscription.remove(); };
  }, []);

  function connect(value: Pairing) {
    disconnect('Connecting…');
    setPairing(value);
    setScanning(false);
    setHint('Pinch, hold, then move together to place a tile.');
    blocked.current = false;
    const next = new PadConnection(value, (status, ready) => {
      if (!alive.current || connection.current !== next) return;
      setMessage(status);
      setConnected(ready);
      if (!ready) stopFrames();
    }, packet => {
      if (!alive.current || connection.current !== next) return;
      if (packet.type === 'ready') {
        void SecureStore.setItemAsync(storageKey, JSON.stringify(value)).catch(() => {
          if (alive.current && connection.current === next) setHint('Connected. Pairing could not be saved on this phone.');
        });
        void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
      }
      if (packet.type === 'armed') void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
      if (packet.type === 'cancelled') blocked.current = touches.current.length > 0;
      if (packet.message && packet.type !== 'pong') setHint(packet.message);
    }, () => { if (connection.current === next) blocked.current = touches.current.length > 0; });
    connection.current = next;
    void next.connect();
  }

  function pump() {
    if (!touches.current.length) { frame.current = null; return; }
    connection.current?.frame(blocked.current ? [] : touches.current, mode.current);
    frame.current = requestAnimationFrame(pump);
  }
  function touch(event: GestureResponderEvent) {
    if (!connected) return;
    const raw = event.nativeEvent.touches;
    if (!raw.length) {
      connection.current?.frame([], mode.current);
      stopFrames();
      blocked.current = false;
      return;
    }
    if (!touches.current.length) mode.current = resize;
    try { touches.current = normalizeTouches(raw, dimensions.current.width, dimensions.current.height); }
    catch {
      blocked.current = true;
      connection.current?.cancel();
      return;
    }
    connection.current?.frame(blocked.current ? [] : touches.current, mode.current);
    if (frame.current === null) frame.current = requestAnimationFrame(pump);
  }
  function cancel() {
    blocked.current = touches.current.length > 0;
    connection.current?.cancel();
    setHint('Cancelled. Lift all fingers to start again.');
  }
  async function scan() {
    disconnect('Ready to pair');
    const result = permission?.granted ? permission : await requestPermission();
    if (!result.granted) { setMessage('Allow camera access in Settings to scan your Mac’s QR.'); return; }
    scanLocked.current = false;
    setScanning(true);
  }

  return <SafeAreaView style={styles.screen}>
    <StatusBar style="light" />
    <View style={styles.header}>
      <View style={styles.headerCopy}><Text style={styles.brand}>OpenTile<Text style={styles.brandLight}> pad</Text></Text><Text style={styles.status}>{message}</Text></View>
      <View style={[styles.dot, connected ? styles.online : styles.offline]} accessibilityLabel={connected ? 'Connected' : 'Disconnected'} />
    </View>
    {scanning ? <View style={styles.surface}>
      <CameraView style={StyleSheet.absoluteFill} barcodeScannerSettings={{ barcodeTypes: ['qr'] }} onBarcodeScanned={({ data }) => {
        if (scanLocked.current) return;
        scanLocked.current = true;
        try { connect(parsePairing(data)); } catch { setMessage('Scan the pairing QR from OpenTile’s Mac menu.'); setScanning(false); }
      }} />
      <View style={styles.scanHint}><Text style={styles.scanText}>Pair Phone Pad… in your Mac’s menu</Text></View>
    </View> : <View style={[styles.surface, !connected && styles.inactive]} onLayout={({ nativeEvent: { layout } }) => {
      dimensions.current = { width: layout.width, height: layout.height };
    }} onStartShouldSetResponder={() => connected} onMoveShouldSetResponder={() => connected}
      onResponderGrant={touch} onResponderMove={touch} onResponderStart={touch} onResponderEnd={touch}
      onResponderRelease={touch} onResponderTerminate={() => { cancel(); stopFrames(); }} onResponderTerminationRequest={() => false}
      accessibilityLabel="Touchpad. One finger moves the pointer. Tap to click. Two fingers scroll. Pinch and hold to move tiles.">
      <View style={styles.padCenter} pointerEvents="none">
        <View style={styles.crossHorizontal} /><View style={styles.crossVertical} />
        <Text style={styles.padLabel}>{connected ? (resize ? 'Pinch to resize' : 'Room to move') : 'A touch closer.'}</Text>
        {!connected ? <Text style={styles.padDescription}>Pair your phone with OpenTile{ '\n' }and make this your trackpad.</Text> : null}
      </View>
      <View style={styles.padFoot} pointerEvents="none"><Text style={styles.padFootText}>{connected ? 'Tap to click     /     Two fingers to scroll' : 'Android + iPhone'}</Text></View>
    </View>}
    {connected ? <>
      <View style={styles.controls}>
        <View style={styles.segment}>
          {[false, true].map(value => <Pressable key={String(value)} accessibilityRole="button" accessibilityState={{ selected: resize === value }} onPress={() => { cancel(); setResize(value); }} style={[styles.mode, resize === value && styles.modeSelected]}><Text style={[styles.modeText, resize === value && styles.modeTextSelected]}>{value ? 'Resize' : 'Move'}</Text></Pressable>)}
        </View>
        <Pressable accessibilityRole="button" onPress={cancel} style={styles.cancel}><Text style={styles.cancelText}>Cancel</Text></Pressable>
      </View>
      <Text style={styles.hint}>{hint}</Text>
      <Pressable accessibilityRole="button" style={styles.quietButton} onPress={() => disconnect('Disconnected. Reconnect when you’re ready.')}><Text style={styles.quietText}>Disconnect</Text></Pressable>
    </> : <>
      <Pressable accessibilityRole="button" style={styles.primary} onPress={() => { if (scanning) setScanning(false); else if (pairing) connect(pairing); else void scan(); }}><Text style={styles.primaryText}>{scanning ? 'Close camera' : pairing ? 'Reconnect to Mac' : 'Scan pairing QR'}</Text></Pressable>
      <Pressable accessibilityRole="button" style={styles.quietButton} onPress={() => { void scan(); }}><Text style={styles.quietText}>{pairing ? 'Pair another Mac' : 'Start with Pair Phone Pad… on your Mac'}</Text></Pressable>
    </>}
  </SafeAreaView>;
}

export default function App() { return <SafeAreaProvider><Pad /></SafeAreaProvider>; }

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#10191E', paddingHorizontal: 22 },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingTop: 20, paddingBottom: 26 },
  headerCopy: { flex: 1 },
  brand: { color: '#F4F6F7', fontSize: 27, fontWeight: '600', letterSpacing: -1 },
  brandLight: { color: '#91A5AF', fontWeight: '300' },
  status: { color: '#A7BAC3', fontSize: 13, marginTop: 7, lineHeight: 19 },
  dot: { width: 9, height: 9, borderRadius: 5, marginLeft: 12 }, online: { backgroundColor: '#93C9DD' }, offline: { backgroundColor: '#5D707B' },
  surface: { flex: 1, minHeight: 200, borderRadius: 32, backgroundColor: '#263942', overflow: 'hidden', borderWidth: 1, borderColor: '#384D58' },
  inactive: { backgroundColor: '#1A2B34' },
  padCenter: { position: 'absolute', top: '40%', width: '100%', alignItems: 'center' },
  crossHorizontal: { width: 30, height: 1, backgroundColor: '#7D9AA8' },
  crossVertical: { width: 1, height: 30, backgroundColor: '#7D9AA8', marginTop: -15 },
  padLabel: { marginTop: 34, color: '#D1E0E6', fontSize: 22, fontWeight: '300', letterSpacing: -0.5 },
  padDescription: { textAlign: 'center', color: '#93AEBB', fontSize: 14, lineHeight: 23, marginTop: 12 },
  padFoot: { position: 'absolute', bottom: 24, width: '100%', alignItems: 'center' }, padFootText: { color: '#8FAAB8', fontSize: 12 },
  controls: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginTop: 20 },
  segment: { flexDirection: 'row', backgroundColor: '#1D2C34', padding: 4, borderRadius: 25 },
  mode: { paddingHorizontal: 24, paddingVertical: 12, borderRadius: 22 }, modeSelected: { backgroundColor: '#B9D8E5' },
  modeText: { color: '#A6BDC7', fontSize: 14, fontWeight: '500' }, modeTextSelected: { color: '#162A34' },
  cancel: { padding: 14 }, cancelText: { color: '#D9E5EB', fontSize: 15 },
  hint: { color: '#A6BDC7', textAlign: 'center', fontSize: 13, lineHeight: 20, minHeight: 40, marginTop: 17 },
  primary: { backgroundColor: '#B9D8E5', borderRadius: 26, alignItems: 'center', padding: 17, marginTop: 24 }, primaryText: { color: '#162A34', fontSize: 16, fontWeight: '600' },
  quietButton: { padding: 15, alignItems: 'center' }, quietText: { color: '#A6BDC7', fontSize: 13, textAlign: 'center' },
  scanHint: { position: 'absolute', bottom: 24, alignSelf: 'center', backgroundColor: '#10191E', padding: 14, borderRadius: 16 }, scanText: { color: '#F4F6F7', fontSize: 13 }
});
