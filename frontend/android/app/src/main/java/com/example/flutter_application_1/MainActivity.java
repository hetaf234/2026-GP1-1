package com.example.flutter_application_1;

import android.app.Activity;
import android.content.Intent;
import android.view.View;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.util.Map;
import org.json.JSONObject;

public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "com.example.misbar/image_capture";
    private static final int REQUEST_IMAGE_CAPTURE = 1001;
    private MethodChannel.Result pendingResult;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if (call.method.equals("openImageCapture")) {
                    Map<String, Object> header = call.argument("header");
                    if (header == null) {
                        result.error("missing_header", "Capture header appearance is required.", null);
                        return;
                    }
                    pendingResult = result;
                    Intent intent = new Intent(this, ImageCaptureActivity.class);
                    intent.putExtra(ImageCaptureActivity.EXTRA_HEADER_APPEARANCE,
                        new JSONObject(header).toString());
                    intent.putExtra(ImageCaptureActivity.EXTRA_STATUS_BAR_COLOR,
                        getWindow().getStatusBarColor());
                    intent.putExtra(ImageCaptureActivity.EXTRA_LIGHT_STATUS_BAR,
                        (getWindow().getDecorView().getSystemUiVisibility()
                            & View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR) != 0);
                    startActivityForResult(intent, REQUEST_IMAGE_CAPTURE);
                } else {
                    result.notImplemented();
                }
            });
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_IMAGE_CAPTURE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                String imagePath = data.getStringExtra(ImageCaptureActivity.EXTRA_IMAGE_PATH);
                if (imagePath == null && data.getData() != null) {
                    imagePath = data.getData().toString();
                }
                if (pendingResult != null) {
                    pendingResult.success(imagePath);
                }
            } else {
                if (pendingResult != null) {
                    pendingResult.success(null);
                }
            }
            pendingResult = null;
        }
    }
}
