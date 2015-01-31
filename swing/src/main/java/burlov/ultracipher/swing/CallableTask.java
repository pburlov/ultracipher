/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 10, 2012
 */
package burlov.ultracipher.swing;

import java.util.concurrent.Callable;

import javax.swing.SwingWorker;

public class CallableTask<T> extends SwingWorker<T, Object> {
    private Callable<T> task;

    public CallableTask(Callable<T> task) {
        super();
        this.task = task;
    }

    @Override
    protected T doInBackground() throws Exception {
        return task.call();
    }

}
