package app.vexplayer.ime;

import android.inputmethodservice.InputMethodService;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * VexPlayer input method: the Mac's own input sources (any language, CJK composition, emoji)
 * produce the text; this IME only puts it into the focused field.
 *
 * Wire format on the abstract socket "vexplayer_ime", both directions:
 * [type: u8][length: u32 big-endian][UTF-8 payload].
 * Host → IME: 'C' commit text, 'M' set composing text (empty clears it), 'S' reset the sensor rate.
 * IME → host: 'H' hello (protocol version), 'F' focus ("1|inputType|keyboard" or "0"), where keyboard is
 * 1 while the app has asked for a keyboard (a game opening its chat) and 0 for a field that is merely focused
 * (games often keep a hidden one focused all the time).
 */
public class VexIME extends InputMethodService {
    private static final String SOCKET = "vexplayer_ime";
    private static final String PROTOCOL = "3";
    /** Background services sometimes leave the emulator's sensor stream fast; see SensorReset. */
    private static final long SENSOR_RESET_INTERVAL_MS = 60_000;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService writer = Executors.newSingleThreadExecutor();
    private volatile DataOutputStream out;
    private volatile boolean running = true;
    private volatile String focus = "0";
    // Main thread only.
    private int editorType = InputType.TYPE_NULL;
    private boolean keyboardRequested;

    private final Runnable sensorReset = new Runnable() {
        @Override
        public void run() {
            SensorReset.run(VexIME.this);
            main.postDelayed(this, SENSOR_RESET_INTERVAL_MS);
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        Thread server = new Thread(this::serve, "vexime-server");
        server.setDaemon(true);
        server.start();
        main.post(sensorReset);
    }

    @Override
    public void onDestroy() {
        running = false;
        main.removeCallbacks(sensorReset);
        writer.shutdownNow();
        super.onDestroy();
    }

    // The Mac keyboard is the keyboard: never cover the game with an on-screen one.
    @Override
    public boolean onEvaluateInputViewShown() {
        return false;
    }

    @Override
    public boolean onEvaluateFullscreenMode() {
        return false;
    }

    @Override
    public void onStartInput(EditorInfo info, boolean restarting) {
        super.onStartInput(info, restarting);
        boolean editable = info != null && (info.inputType & InputType.TYPE_MASK_CLASS) != InputType.TYPE_NULL;
        editorType = editable ? info.inputType : InputType.TYPE_NULL;
        if (!restarting) keyboardRequested = false;
        reportFocus();
    }

    /** The app asked for a keyboard (showSoftInput). Still never show one: the Mac keyboard types. */
    @Override
    public boolean onShowInputRequested(int flags, boolean configChange) {
        if (editorType != InputType.TYPE_NULL && !keyboardRequested) {
            keyboardRequested = true;
            reportFocus();
        }
        return false;
    }

    /** Called for hideSoftInput too, even though no window was ever shown. */
    @Override
    public void hideWindow() {
        if (keyboardRequested) {
            keyboardRequested = false;
            reportFocus();
        }
        super.hideWindow();
    }

    @Override
    public void onFinishInput() {
        super.onFinishInput();
        editorType = InputType.TYPE_NULL;
        keyboardRequested = false;
        reportFocus();
    }

    private void reportFocus() {
        send('F', editorType == InputType.TYPE_NULL ? "0" : "1|" + editorType + "|" + (keyboardRequested ? 1 : 0));
    }

    private void serve() {
        LocalServerSocket server = null;
        while (running) {
            try {
                if (server == null) server = new LocalServerSocket(SOCKET);
                LocalSocket client = server.accept();
                handle(client);
            } catch (IOException e) {
                try {
                    Thread.sleep(500);
                } catch (InterruptedException ignored) {
                    return;
                }
            }
        }
    }

    private void handle(LocalSocket client) {
        try (LocalSocket socket = client;
             DataInputStream in = new DataInputStream(new BufferedInputStream(socket.getInputStream()));
             DataOutputStream o = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()))) {
            out = o;
            send('H', PROTOCOL);
            send('F', focus);
            while (running) {
                int type = in.readUnsignedByte();
                int length = in.readInt();
                if (length < 0 || length > (1 << 20)) return;
                byte[] payload = new byte[length];
                in.readFully(payload);
                String text = new String(payload, StandardCharsets.UTF_8);
                main.post(() -> apply(type, text));
            }
        } catch (IOException ignored) {
            // Host went away; wait for the next connection.
        } finally {
            out = null;
        }
    }

    private void apply(int type, String text) {
        if (type == 'S') {
            SensorReset.run(this);
            return;
        }
        InputConnection ic = getCurrentInputConnection();
        if (ic == null) return;
        switch (type) {
            case 'C':
                ic.commitText(text, 1);
                break;
            case 'M':
                if (text.isEmpty()) {
                    ic.setComposingText("", 1);
                    ic.finishComposingText();
                } else {
                    ic.setComposingText(text, 1);
                }
                break;
            default:
                break;
        }
    }

    private void send(char type, String payload) {
        if (type == 'F') focus = payload;
        writer.execute(() -> {
            DataOutputStream o = out;
            if (o == null) return;
            try {
                byte[] bytes = payload.getBytes(StandardCharsets.UTF_8);
                o.writeByte(type);
                o.writeInt(bytes.length);
                o.write(bytes);
                o.flush();
            } catch (IOException e) {
                out = null;
            }
        });
    }
}
