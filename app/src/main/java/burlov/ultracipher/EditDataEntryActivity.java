package burlov.ultracipher;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.View;
import android.widget.Button;
import android.widget.TextView;

import de.burlov.ultracipher.core.DataEntry;

public class EditDataEntryActivity extends Activity {
    private TextView textLabel;
    private TextView textTags;
    private TextView textData;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_edit_data_entry);
        textLabel = (TextView) findViewById(R.id.editEntryLabel);
        textTags = (TextView) findViewById(R.id.editEntryTags);
        textData = (TextView) findViewById(R.id.editEntryData);
        DataEntry entry = (DataEntry) getIntent().getSerializableExtra("entry");
        textLabel.setText(entry.getName());
        textTags.setText(entry.getTags());
        textData.setText(entry.getText());
        Button bt = (Button) findViewById(R.id.buttonOk);
        bt.setOnClickListener(new View.OnClickListener() {

            @Override
            public void onClick(View v) {
                doOk(v);
            }
        });
        bt = (Button) findViewById(R.id.buttonCancel);
        bt.setOnClickListener(new View.OnClickListener() {

            @Override
            public void onClick(View v) {
                doCancel(v);
            }
        });
    }

    private void doCancel(View view) {
        setResult(RESULT_CANCELED);
        finish();
    }

    private void doOk(View view) {
        DataEntry entry = (DataEntry) getIntent().getSerializableExtra("entry");
        entry.setName(textLabel.getText().toString());
        entry.setTags(textTags.getText().toString());
        entry.setText(textData.getText().toString());
        setResult(RESULT_OK, getIntent());
        finish();
    }

    private SharedPreferences getPreferences() {
        SharedPreferences preferences = getSharedPreferences("ultacipher", MODE_PRIVATE);
        return preferences;
    }

}
