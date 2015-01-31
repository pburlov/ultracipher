package burlov.ultracipher;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Menu;
import android.view.MenuItem;
import android.widget.TextView;

import de.burlov.ultracipher.core.DataEntry;

public class EditDataEntryActivity extends Activity {
    public static final int RESULT_ENTRY_EDITED = 1001;
    public static final int INTENT_SHOW_DATA_ENTRY = 1002;
    public static final int INTENT_NEW_DATA_ENTRY = 1003;
    private TextView textLabel;
    private TextView textTags;
    private TextView textData;
    private MenuItem menuItemEdit;
    private MenuItem menuItemEditAccept;
    private MenuItem menuItemEditCancel;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_edit_data_entry);
        textLabel = (TextView) findViewById(R.id.editEntryLabel);
        textTags = (TextView) findViewById(R.id.editEntryTags);
        textData = (TextView) findViewById(R.id.editEntryData);
        showDataFromIntent();
    }

    private void showDataFromIntent() {
        DataEntry entry = (DataEntry) getIntent().getSerializableExtra("entry");
        textLabel.setText(entry.getName());
        textTags.setText(entry.getTags());
        textData.setText(entry.getText());
    }

    @Override
    public boolean onCreateOptionsMenu(Menu menu) {
        getMenuInflater().inflate(R.menu.edit_entry, menu);
        menuItemEdit = menu.findItem(R.id.menuItemEdit);
        menuItemEditAccept = menu.findItem(R.id.menuItemEditAccept);
        menuItemEditCancel = menu.findItem(R.id.menuItemEditCancel);
        if (getIntent().getIntExtra("requestCode", INTENT_SHOW_DATA_ENTRY) == INTENT_SHOW_DATA_ENTRY) {
            switchToEditMode(false);
        } else {
            switchToEditMode(true);
        }
        return super.onCreateOptionsMenu(menu);

    }

    @Override
    public boolean onOptionsItemSelected(MenuItem item) {
        switch (item.getItemId()) {
            case R.id.menuItemEdit:
                switchToEditMode(true);
                break;
            case R.id.menuItemEditCancel:
                cancelEdit();
                break;
            case R.id.menuItemEditAccept:
                acceptEdit();
                break;
        }
        return super.onOptionsItemSelected(item);
    }

    private void acceptEdit() {
        switchToEditMode(false);
        DataEntry entry = (DataEntry) getIntent().getSerializableExtra("entry");
        entry.setName(textLabel.getText().toString());
        entry.setTags(textTags.getText().toString());
        entry.setText(textData.getText().toString());
        setResult(RESULT_ENTRY_EDITED, getIntent());
        finish();
    }

    private void cancelEdit() {
        switchToEditMode(false);
        showDataFromIntent();
        //        setResult(RESULT_NO_CHANGES);
        //        finish();
    }

    private void switchToEditMode(boolean edit) {
        textLabel.setEnabled(edit);
        textLabel.setTextColor(Color.BLACK);
        textData.setEnabled(edit);
        textData.setTextColor(Color.BLACK);
        textTags.setEnabled(edit);
        textTags.setTextColor(Color.BLACK);
        menuItemEdit.setVisible(!edit);
        menuItemEditAccept.setVisible(edit);
        menuItemEditCancel.setVisible(edit);
    }
}
