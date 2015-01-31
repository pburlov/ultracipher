/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 9, 2012
 */
package burlov.ultracipher.swing;

import javax.swing.SwingWorker;

import de.burlov.ultracipher.core.ICryptor;
import de.burlov.ultracipher.core.IProgressListener;
import de.burlov.ultracipher.core.KeyGenPerformanceLevel;
import de.burlov.ultracipher.core.Ultracipher;

public class CreateCryptorTask extends SwingWorker<ICryptor, Object> {
    private char[] passphrase;

    public CreateCryptorTask(char[] passphrase) {
        super();
        this.passphrase = passphrase;
    }

    @Override
    protected ICryptor doInBackground() throws Exception {
        return Ultracipher.createCryptor(passphrase, KeyGenPerformanceLevel.DEFAULT, new IProgressListener() {

            @Override
            public boolean currentProgress(float workDone, float workToDo) {
                CreateCryptorTask.this.setProgress((int) (workDone * 100 / workToDo));
                return true;
            }
        });
    }

}
