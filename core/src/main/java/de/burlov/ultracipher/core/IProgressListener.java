/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 9, 2012
 */
package de.burlov.ultracipher.core;

public interface IProgressListener {

    /**
     * @param workDone aktuellen Progressstand
     * @param workToDo wieviel insgesamt gemacht werden soll
     * @return 'true' wenn Operation weiter laufen soll, 'false' wenn Operation
     * abgebrochen werden soll
     */
    public boolean currentProgress(float workDone, float workToDo);
}
