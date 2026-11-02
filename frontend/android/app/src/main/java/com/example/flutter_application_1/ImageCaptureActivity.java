package com.example.flutter_application_1;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.AccelerateDecelerateInterpolator;
import android.view.animation.Animation;
import android.view.animation.TranslateAnimation;
import android.widget.ImageView;
import android.widget.ImageButton;
import android.widget.TextView;
import android.widget.Toast;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;
import io.flutter.FlutterInjector;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import org.json.JSONException;
import org.json.JSONObject;

public class ImageCaptureActivity extends AppCompatActivity {
    public static final String EXTRA_IMAGE_PATH = "image_path";
    public static final String EXTRA_HEADER_APPEARANCE = "header_appearance";
    public static final String EXTRA_STATUS_BAR_COLOR = "status_bar_color";
    public static final String EXTRA_LIGHT_STATUS_BAR = "light_status_bar";

    private JSONObject headerAppearance;

    private Uri tempCameraUri;
    private String tempCameraPath;

    private final ActivityResultLauncher<Uri> takePictureLauncher =
        registerForActivityResult(new ActivityResultContracts.TakePicture(), success -> {
            if (Boolean.TRUE.equals(success) && tempCameraPath != null) {
                returnSuccess(tempCameraPath);
            } else {
                cleanupTempCameraFile();
            }
        });

    private final ActivityResultLauncher<String> pickImageLauncher =
        registerForActivityResult(new ActivityResultContracts.GetContent(), uri -> {
            if (uri != null) {
                copySelectedImageToCache(uri);
            }
        });

    private final ActivityResultLauncher<String> requestCameraPermissionLauncher =
        registerForActivityResult(new ActivityResultContracts.RequestPermission(), isGranted -> {
            if (Boolean.TRUE.equals(isGranted)) {
                launchCamera();
            } else {
                Toast.makeText(this, "Camera permission is required to take photos", Toast.LENGTH_SHORT).show();
            }
        });

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_image_capture);

        // Use AppHeader's design contract for this native view as well.
        try {
            headerAppearance = new JSONObject(getIntent().getStringExtra(EXTRA_HEADER_APPEARANCE));
            applyHeaderAppearance();
        } catch (JSONException | NullPointerException error) {
            setResult(RESULT_CANCELED);
            finish();
            return;
        }
        loadLogoImage();

        // Clear any old temp images from cache
        try {
            File storageDir = new File(getCacheDir(), "images");
            if (storageDir.exists()) {
                File[] files = storageDir.listFiles();
                if (files != null) {
                    for (File f : files) {
                        f.delete();
                    }
                }
            }
        } catch (Exception ignored) {}

        findViewById(R.id.btn_back).setOnClickListener(v -> {
            setResult(RESULT_CANCELED);
            finish();
        });

        findViewById(R.id.btn_capture).setOnClickListener(v -> {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                launchCamera();
            } else {
                requestCameraPermissionLauncher.launch(Manifest.permission.CAMERA);
            }
        });

        findViewById(R.id.btn_upload_image).setOnClickListener(v -> {
            pickImageLauncher.launch("image/*");
        });

        findViewById(R.id.btn_flash).setOnClickListener(v -> {
            Toast.makeText(this, "Flash toggled", Toast.LENGTH_SHORT).show();
        });
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            startLaserAnimation();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        startLaserAnimation();
    }

    private float pixels(String property) throws JSONException {
        return (float) headerAppearance.getDouble(property)
            * getResources().getDisplayMetrics().density;
    }

    private void applyHeaderAppearance() throws JSONException {
        View header = findViewById(R.id.capture_header);
        int top = Math.round(pixels("paddingTop"));
        int bottom = Math.round(pixels("paddingBottom"));
        header.setPadding(Math.round(pixels("paddingLeft")), top,
            Math.round(pixels("paddingRight")), bottom);
        ViewGroup.LayoutParams headerLayout = header.getLayoutParams();
        headerLayout.height = Math.round(pixels("contentHeight")) + top + bottom;
        header.setLayoutParams(headerLayout);
        header.setBackgroundColor((int) headerAppearance.getLong("backgroundColor"));
        getWindow().setBackgroundDrawable(new ColorDrawable(
            (int) headerAppearance.getLong("backgroundColor")));
        getWindow().setStatusBarColor(getIntent().getIntExtra(
            EXTRA_STATUS_BAR_COLOR, getWindow().getStatusBarColor()));
        View decor = getWindow().getDecorView();
        int systemUi = decor.getSystemUiVisibility() & ~View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
        if (getIntent().getBooleanExtra(EXTRA_LIGHT_STATUS_BAR, false)) {
            systemUi |= View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
        }
        decor.setSystemUiVisibility(systemUi);
        header.setLayoutDirection(headerAppearance.getBoolean("rightToLeft")
            ? View.LAYOUT_DIRECTION_RTL : View.LAYOUT_DIRECTION_LTR);

        View logo = findViewById(R.id.capture_header_logo);
        ViewGroup.LayoutParams logoLayout = logo.getLayoutParams();
        logoLayout.width = Math.round(pixels("logoWidth"));
        logoLayout.height = Math.round(pixels("logoHeight"));
        logo.setLayoutParams(logoLayout);
        // RelativeLayout centers within its full height; Flutter centers inside
        // the asymmetric top/bottom padding. Keep both centers identical.
        float centerOffset = (top - bottom) / 2f;
        logo.setTranslationY(centerOffset);

        int foreground = (int) headerAppearance.getLong("foregroundColor");
        ImageButton back = findViewById(R.id.btn_back);
        ViewGroup.LayoutParams backLayout = back.getLayoutParams();
        backLayout.width = backLayout.height = Math.round(pixels("actionSize"));
        back.setLayoutParams(backLayout);
        back.setTranslationY(centerOffset);
        int iconPadding = Math.round((pixels("actionSize") - pixels("actionIconSize")) / 2);
        back.setPadding(iconPadding, iconPadding, iconPadding, iconPadding);
        back.setImageTintList(ColorStateList.valueOf(foreground));
        GradientDrawable shape = new GradientDrawable();
        shape.setColor((int) headerAppearance.getLong("actionBackgroundColor"));
        shape.setCornerRadius(pixels("actionRadius"));
        back.setBackground(new RippleDrawable(
            ColorStateList.valueOf((foreground & 0x00ffffff) | 0x1f000000), shape, null));
        TextView fallback = findViewById(R.id.tv_brand_logo_fallback);
        fallback.setTextColor(foreground);
    }

    private void loadLogoImage() {
        ImageView ivLogo = findViewById(R.id.iv_brand_logo);
        TextView tvFallback = findViewById(R.id.tv_brand_logo_fallback);

        Bitmap logoBitmap = null;

        // 1. Try Flutter asset lookup key
        try {
            String assetKey = FlutterInjector.instance()
                .flutterLoader()
                .getLookupKeyForAsset(headerAppearance.optString("logoAsset"));
            try (InputStream is = getAssets().open(assetKey)) {
                logoBitmap = BitmapFactory.decodeStream(is);
            }
        } catch (Exception ignored) {}

        // 2. Direct flutter_assets fallback path
        if (logoBitmap == null) {
            try (InputStream is = getAssets().open("flutter_assets/" + headerAppearance.optString("logoAsset"))) {
                logoBitmap = BitmapFactory.decodeStream(is);
            } catch (Exception ignored) {}
        }

        if (logoBitmap != null && ivLogo != null) {
            // Match Image.asset's decode size, logical artwork size and central crop.
            int decodeSize = headerAppearance.optInt("logoDecodeSize");
            Bitmap decoded = Bitmap.createScaledBitmap(logoBitmap, decodeSize, decodeSize, true);
            decoded.setDensity(Bitmap.DENSITY_NONE);
            ivLogo.setImageBitmap(decoded);
            ivLogo.addOnLayoutChangeListener((view, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom) -> {
                float artworkPixels = (float) headerAppearance.optDouble("logoArtworkSize")
                    * getResources().getDisplayMetrics().density;
                float scale = artworkPixels / decoded.getWidth();
                Matrix matrix = new Matrix();
                matrix.setScale(scale, scale);
                matrix.postTranslate(((right - left) - artworkPixels) / 2f,
                    ((bottom - top) - artworkPixels) / 2f);
                ivLogo.setImageMatrix(matrix);
            });
            ivLogo.setVisibility(View.VISIBLE);
            if (tvFallback != null) tvFallback.setVisibility(View.GONE);
        } else if (tvFallback != null) {
            tvFallback.setVisibility(View.VISIBLE);
        }
    }

    private void startLaserAnimation() {
        View laserLine = findViewById(R.id.view_laser_line);
        if (laserLine != null) {
            laserLine.clearAnimation();
            float distance = 150f * getResources().getDisplayMetrics().density;
            TranslateAnimation animation = new TranslateAnimation(
                Animation.ABSOLUTE, 0f,
                Animation.ABSOLUTE, 0f,
                Animation.ABSOLUTE, 0f,
                Animation.ABSOLUTE, distance
            );
            animation.setDuration(1600);
            animation.setRepeatCount(Animation.INFINITE);
            animation.setRepeatMode(Animation.REVERSE);
            animation.setInterpolator(new AccelerateDecelerateInterpolator());
            laserLine.startAnimation(animation);
        }
    }

    private void launchCamera() {
        try {
            File photoFile = createCacheImageFile();
            tempCameraPath = photoFile.getAbsolutePath();
            tempCameraUri = FileProvider.getUriForFile(
                this,
                getPackageName() + ".fileprovider",
                photoFile
            );
            takePictureLauncher.launch(tempCameraUri);
        } catch (Exception e) {
            Toast.makeText(this, "Failed to initialize camera: " + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    private void copySelectedImageToCache(Uri sourceUri) {
        try {
            File targetFile = createCacheImageFile();
            try (InputStream in = getContentResolver().openInputStream(sourceUri);
                 FileOutputStream out = new FileOutputStream(targetFile)) {
                if (in != null) {
                    byte[] buffer = new byte[8192];
                    int bytesRead;
                    while ((bytesRead = in.read(buffer)) != -1) {
                        out.write(buffer, 0, bytesRead);
                    }
                }
            }
            returnSuccess(targetFile.getAbsolutePath());
        } catch (Exception e) {
            Toast.makeText(this, "Failed to load selected photo", Toast.LENGTH_SHORT).show();
        }
    }

    private File createCacheImageFile() throws Exception {
        String timeStamp = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.getDefault()).format(new Date());
        File storageDir = new File(getCacheDir(), "images");
        if (!storageDir.exists()) {
            storageDir.mkdirs();
        }
        return new File(storageDir, "IMG_" + timeStamp + ".jpg");
    }

    private void cleanupTempCameraFile() {
        if (tempCameraPath != null) {
            try {
                File f = new File(tempCameraPath);
                if (f.exists() && f.length() == 0) {
                    f.delete();
                }
            } catch (Exception ignored) {}
            tempCameraPath = null;
            tempCameraUri = null;
        }
    }

    private void returnSuccess(String imagePath) {
        Intent resultIntent = new Intent();
        resultIntent.putExtra(EXTRA_IMAGE_PATH, imagePath);
        setResult(RESULT_OK, resultIntent);
        finish();
    }

    @Override
    public void onBackPressed() {
        super.onBackPressed();
        setResult(RESULT_CANCELED);
        finish();
    }
}
