package app.vexplayer.ime;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Lets the host reset the sensor rate over adb when VexIME is not the active input method. */
public class SensorResetReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        PendingResult result = goAsync();
        SensorReset.run(context.getApplicationContext());
        new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(result::finish, 500);
    }
}
