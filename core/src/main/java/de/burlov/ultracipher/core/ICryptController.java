package de.burlov.ultracipher.core;

/**
 * @author paul
 *         <p/>
 *         created May 30, 2012
 */
public interface ICryptController {
    /**
     * Callback Methode. Wird aufgerufen wenn naechste Runde der
     * ver/entschluesselung durchgefuehrt wurde
     *
     * @param data
     * @return'true' wenn die Berechnung weitergefuehrt werden soll. Zum
     * Abbrechen 'false'
     */
    public boolean roundDone(byte[] data);
}
