/**************************************************************************/
/*  GodotApp.java                                                         */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

package com.godot.game;

import org.godotengine.godot.Godot;
import org.godotengine.godot.GodotActivity;

import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;

import androidx.activity.EdgeToEdge;
import androidx.activity.BackEventCompat;
import androidx.activity.OnBackPressedCallback;
import androidx.core.splashscreen.SplashScreen;

/**
 * Template activity for Godot Android builds.
 * Feel free to extend and modify this class for your custom logic.
 */
public class GodotApp extends GodotActivity {
    private OnBackPressedCallback pokeWildsBack;

    private void installPokeWildsBack() {
        if (pokeWildsBack != null) pokeWildsBack.remove();
        pokeWildsBack = new OnBackPressedCallback(true) {
            private boolean rightEdge;
            @Override public void handleOnBackStarted(BackEventCompat event) {
                rightEdge = event.getSwipeEdge() == BackEventCompat.EDGE_RIGHT;
            }
            @Override public void handleOnBackCancelled() { rightEdge = false; }
            @Override public void handleOnBackPressed() {
                PokeWildsBack.submit(rightEdge);
                rightEdge = false;
            }
        };
        getOnBackPressedDispatcher().addCallback(this, pokeWildsBack);
    }
	static {
		// .NET libraries.
		if (BuildConfig.FLAVOR.equals("mono")) {
			try {
				Log.v("GODOT", "Loading System.Security.Cryptography.Native.Android library");
				System.loadLibrary("System.Security.Cryptography.Native.Android");
			} catch (UnsatisfiedLinkError e) {
				Log.e("GODOT", "Unable to load System.Security.Cryptography.Native.Android library");
			}
		}
	}

	private final Runnable updateWindowAppearance = () -> {
		Godot godot = getGodot();
		if (godot != null) {
			godot.enableImmersiveMode(godot.isInImmersiveMode(), true);
			godot.enableEdgeToEdge(godot.isInEdgeToEdgeMode(), true);
			godot.setSystemBarsAppearance();
		}
	};

	@Override
	public void onCreate(Bundle savedInstanceState) {
		PokeWildsStorage.initialize(this);
		SplashScreen splashScreen = SplashScreen.installSplashScreen(this);
		EdgeToEdge.enable(this);
		super.onCreate(savedInstanceState);

		Godot godot = getGodot();
		if (godot != null && godot.getDisableGodotSplash()) {
			splashScreen.setKeepOnScreenCondition(() -> godot.getRunStatus() != Godot.RunStatus.STARTED);
		}
	}

	@Override
	public void onResume() {
		super.onResume();
		updateWindowAppearance.run();
	}

	@Override
    public void onGodotMainLoopStarted() {
        super.onGodotMainLoopStarted();
        runOnUiThread(() -> {
            updateWindowAppearance.run();
            installPokeWildsBack();
            disableFocusHighlight(getWindow().getDecorView());
        });
	}

	/**
	 * On a controller-driven device Android draws its default focus highlight
	 * over the focused view. After the on-screen keyboard closes that view is
	 * the whole game, which dims the screen by about 30% until the app restarts.
	 */
	private static void disableFocusHighlight(View view) {
		if (view == null) return;
		if (Build.VERSION.SDK_INT >= 26) view.setDefaultFocusHighlightEnabled(false);
		if (view instanceof ViewGroup) {
			ViewGroup group = (ViewGroup) view;
			for (int i = 0; i < group.getChildCount(); i++) disableFocusHighlight(group.getChildAt(i));
		}
	}

	/**
	 * While the on-screen keyboard is open Godot's hidden text field has focus
	 * and swallows controller buttons. Hand them to the game instead, so A can
	 * confirm and B can cancel what is being typed.
	 */
	@Override
	public boolean dispatchKeyEvent(KeyEvent event) {
		Godot godot = getGodot();
		boolean pad = (event.getSource() & InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD
				&& KeyEvent.isGamepadButton(event.getKeyCode());
		if (pad && godot != null && godot.getRenderView() != null && getCurrentFocus() instanceof EditText) {
			if (event.getAction() == KeyEvent.ACTION_DOWN) {
				godot.getRenderView().getInputHandler().onKeyDown(event.getKeyCode(), event);
			} else if (event.getAction() == KeyEvent.ACTION_UP) {
				godot.getRenderView().getInputHandler().onKeyUp(event.getKeyCode(), event);
			}
			return true;
		}
		return super.dispatchKeyEvent(event);
	}

	@Override
	public void onGodotForceQuit(Godot instance) {
		if (!BuildConfig.FLAVOR.equals("instrumented")) {
			// For instrumented builds, we disable force-quitting to allow the instrumented tests to complete
			// successfully, otherwise they fail when the process crashes.
			super.onGodotForceQuit(instance);
		}
	}

	@Override
	protected boolean isPiPEnabled() {
		return true;
	}
}
