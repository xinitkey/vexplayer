package app.vexplayer.ime;

import android.content.Context;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Handler;
import android.os.Looper;

/**
 * Brings the emulator's sensor stream back down to 1 Hz.
 *
 * The goldfish sensors HAL switches every host sensor on at start-up and never off again;
 * deactivating a sensor only clears a guest-side bit. The host keeps sending all of them
 * at the "set-delay" rate, which the HAL recomputes only inside batch(), as the shortest
 * period among the sensors active at that moment. So after any app has used a sensor at
 * 50 Hz, the emulator streams every sensor at 50 Hz forever, even with nobody listening.
 *
 * Registering a listener calls batch() before activate(): with nothing else active the HAL
 * computes its 1 s maximum. While a game holds sensors, the minimum stays the game's rate,
 * so this is harmless to call at any time.
 */
final class SensorReset {
    private static final SensorEventListener IGNORE = new SensorEventListener() {
        @Override
        public void onSensorChanged(SensorEvent event) {}

        @Override
        public void onAccuracyChanged(Sensor sensor, int accuracy) {}
    };

    private SensorReset() {}

    static void run(Context context) {
        SensorManager sensors = (SensorManager) context.getSystemService(Context.SENSOR_SERVICE);
        if (sensors == null) return;
        Sensor accelerometer = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
        if (accelerometer == null) return;
        Handler main = new Handler(Looper.getMainLooper());
        main.post(() -> {
            sensors.registerListener(IGNORE, accelerometer, SensorManager.SENSOR_DELAY_NORMAL);
            main.postDelayed(() -> sensors.unregisterListener(IGNORE), 200);
        });
    }
}
