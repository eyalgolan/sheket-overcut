package app.sheket.ui

import android.app.Activity
import android.os.Bundle
import android.widget.TextView
import app.sheket.BuildConfig
import app.sheket.R

/**
 * The about and privacy screen (spec section 5). All text is static and comes
 * from the layout; only the app version is filled in at runtime. No network,
 * file I/O or state.
 *
 * The privacy text is a placeholder until the owner and a lawyer supply the
 * wording (spec section 8, risk 6).
 */
class AboutActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_about)
        findViewById<TextView>(R.id.about_version).text =
            getString(R.string.about_version, BuildConfig.VERSION_NAME)
    }
}
