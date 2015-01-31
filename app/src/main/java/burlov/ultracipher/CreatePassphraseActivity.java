package burlov.ultracipher;

import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.widget.TextView;

public class CreatePassphraseActivity extends Activity {
    /**
     * Called when the activity is first created.
     */
    TextView t1;
    TextView t2;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.createpassphrase);
        t1 = (TextView) findViewById(R.id.passphrase);
        t2 = (TextView) findViewById(R.id.passphraseConfirm);
    }

    public void createPassphrase(View view) {
        if (!checkPassphrase()) {
            // TODO Fehlerdialog
        }
        // setResult(RESULT_OK, data)
    }

    public void clear(View view) {
        t1.setText("");
        t2.setText("");
    }

    private boolean checkPassphrase() {
        return t1.getText().equals(t2.getText());
    }
}