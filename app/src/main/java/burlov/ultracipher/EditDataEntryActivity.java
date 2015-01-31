package burlov.ultracipher;

import android.app.Activity;
import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
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
        this.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
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

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
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
        if (edit) {
            if (textLabel.getKeyListener() == null) {
                textLabel.setKeyListener((android.text.method.KeyListener) textLabel.getTag());
            }
            if (textData.getKeyListener() == null) {
                textData.setKeyListener((android.text.method.KeyListener) textData.getTag());
            }
            if (textTags.getKeyListener() == null) {
                textTags.setKeyListener((android.text.method.KeyListener) textTags.getTag());
            }
        } else {
            //Remove KeyListener, so the colors does not changes and copy/paste works as always
            if (textLabel.getKeyListener() != null) {
                textLabel.setTag(textLabel.getKeyListener());
                textLabel.setKeyListener(null);
            }
            if (textData.getKeyListener() != null) {
                textData.setTag(textData.getKeyListener());
                textData.setKeyListener(null);
            }
            if (textTags.getKeyListener() != null) {
                textTags.setTag(textTags.getKeyListener());
                textTags.setKeyListener(null);
            }
        }
        menuItemEdit.setVisible(!edit);
        menuItemEditAccept.setVisible(edit);
        menuItemEditCancel.setVisible(edit);

    }
}
