/*
 	Copyright (C) 2012 Paul Burlov
 	
 	
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
package burlov.ultracipher.swing;

import org.apache.commons.io.FileUtils;
import org.apache.commons.lang3.ObjectUtils;
import org.apache.commons.lang3.StringUtils;
import org.apache.commons.lang3.SystemUtils;
import org.jdesktop.swingx.JXErrorPane;
import org.jdesktop.swingx.error.ErrorInfo;

import java.awt.FontFormatException;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.awt.event.KeyEvent;
import java.awt.event.WindowEvent;
import java.awt.event.WindowListener;
import java.io.File;
import java.io.IOException;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.util.Arrays;
import java.util.Properties;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.atomic.AtomicReference;
import java.util.prefs.Preferences;

import javax.swing.Box;
import javax.swing.ButtonGroup;
import javax.swing.ImageIcon;
import javax.swing.JFileChooser;
import javax.swing.JFrame;
import javax.swing.JMenu;
import javax.swing.JMenuBar;
import javax.swing.JMenuItem;
import javax.swing.JOptionPane;
import javax.swing.JRadioButtonMenuItem;
import javax.swing.JSeparator;
import javax.swing.KeyStroke;
import javax.swing.SwingUtilities;
import javax.swing.SwingWorker;
import javax.swing.UIManager;
import javax.swing.UIManager.LookAndFeelInfo;
import javax.swing.WindowConstants;

import de.burlov.ultracipher.core.CSVSettings;
import de.burlov.ultracipher.core.Database;
import de.burlov.ultracipher.core.Ultracipher;
import de.burlov.ultracipher.core.Ultracipher.SyncResult;
import de.burlov.ultracipher.core.mail.EmailCredentials;

/**
 * Created 26.03.2009
 *
 * @author paul
 */
public class SwingGuiApplication {
    static final String DATA_FILE_NAME = "ultracipher.dat";
    static File fileToLoad;
    static private SwingGuiApplication instance;
    /*
     * Aktuelle geladene Datenbank
     */
    private Ultracipher core = new Ultracipher(new PrintWriter(System.out, true));
    private Translator translator = new Translator();
    private MainPanel mainPanel = new MainPanel(translator);
    private ScreenKeyboard screenKeyboard = new ScreenKeyboard(getAppIcon().getImage());
    private JFrame digester = new FileDigester();
    /*
     * Signalisiert lokale Aenderungen
     */
    private boolean hasChanges = false;
    /*
     * Signalisiert ob schon eine Sync-Operation waehrend der Laufzeit
     * durchgefuehrt wurde
     */
    private boolean synced = false;
    private File loadedFile;
    private JFrame mainFrame;

    public static void main(String[] args) throws IOException, FontFormatException {
        if (args.length > 0) {
            fileToLoad = new File(args[0]);
        }
        SwingUtilities.invokeLater(new Runnable() {

            @Override
            public void run() {
                initLAF();
                new SwingGuiApplication().startup();
            }
        });
    }

    public static SwingGuiApplication getInstance() {
        return instance;
    }

    public static ImageIcon getAppIcon() {
        return new ImageIcon(SwingGuiApplication.class.getResource("uc-metal.png"));
    }

    static void initLAF() {
        try {
            UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName());
        } catch (Exception e1) {
            e1.printStackTrace();
        }
        try {
            for (LookAndFeelInfo info : UIManager.getInstalledLookAndFeels()) {
                if ("Nimbus".equals(info.getName())) {
                    UIManager.setLookAndFeel(info.getClassName());
                    break;
                }
            }
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    /**
     * Methode sammelt Informationen ueber Systemumgebung
     *
     * @return
     */
    static public StringBuilder createSystemInfo() {
        StringBuilder sb = new StringBuilder();
        Properties p = System.getProperties();
        for (Object key : p.keySet()) {
            if (key.toString().endsWith("path")) {
                continue;//Zu lange Werte werden nicht gebraucht
            }
            String value = (String) p.get(key);
            sb.append(key);
            sb.append(": ");
            sb.append(value);
            sb.append('\n');
        }
        return sb;
    }

    /*
     * (non-Javadoc)
     *
     * @see org.jdesktop.application.Application#startup()
     */
    protected void startup() {
        initLAF();
        mainFrame = new JFrame(getFrameTitle());

        mainFrame.setIconImage(getAppIcon().getImage());
        mainFrame.setDefaultCloseOperation(WindowConstants.DO_NOTHING_ON_CLOSE);
        instance = this;
        mainFrame.addWindowListener(new WindowListener() {

            @Override
            public void windowOpened(WindowEvent e) {
            }

            @Override
            public void windowIconified(WindowEvent e) {
            }

            @Override
            public void windowDeiconified(WindowEvent e) {
            }

            @Override
            public void windowDeactivated(WindowEvent e) {
            }

            @Override
            public void windowClosing(WindowEvent e) {
                if (canExit()) {
                    exit();
                }
                mainFrame.setVisible(true);
            }

            @Override
            public void windowClosed(WindowEvent e) {

            }

            @Override
            public void windowActivated(WindowEvent e) {
            }
        });
        getMainFrame().setJMenuBar(createMenuBar());
        getMainFrame().add(mainPanel);
        restoreWindowState();
        mainFrame.setVisible(true);
        mainPanel.getEditDataPanel().setEditable(false);
        loadLocalData();
        downloadAndMergeData();
        mainPanel.init();
    }

    protected void exit() {
        core.clear();
        saveWindowState();
        System.exit(0);
    }

    private String getFrameTitle() {
        return "Ultracipher" + (hasChanges ? "(*)" : "");
        // return "ᚢᛚᛏᚱᚫ ᛉᛁᛓᛖᚱ"+(needLocalSave || needUpload ? "(*)":"");
    }

    private void saveWindowState() {
        Preferences prefs = Preferences.userNodeForPackage(getClass());
        prefs.putInt("size.x", mainFrame.getWidth());
        prefs.putInt("size.y", mainFrame.getHeight());
        prefs.putInt("pos.x", mainFrame.getX());
        prefs.putInt("pos.y", mainFrame.getY());
    }

    private void restoreWindowState() {
        Preferences prefs = Preferences.userNodeForPackage(getClass());
        mainFrame.setSize(prefs.getInt("size.x", 600), prefs.getInt("size.y", 400));
        mainFrame.setLocationRelativeTo(null);
        mainFrame.setLocation(prefs.getInt("pos.x", 100), prefs.getInt("pos.y", 100));

    }

    public boolean canExit() {
        if (hasChanges) {
            /*
             * Wenn es ungespeicherte Aenderungen gibt, dann Benutzer fragen
			 */
            int ret = JOptionPane.showConfirmDialog(getMainFrame(), "Save changes before exit?", "",
                    JOptionPane.YES_NO_CANCEL_OPTION);
            switch (ret) {
                case JOptionPane.CANCEL_OPTION:
                    return false;
                case JOptionPane.NO_OPTION:
                    return true;
                case JOptionPane.YES_OPTION:
                /*
				 * Speichern anstossen
				 */
                    saveDatabase();
				/*
				 * Nur wenn Speichern erfolgreich war 'true' zurueckgeben
				 */
                    return !hasChanges;
                default:
                    return false;
            }
        } else {
            return true;
        }
    }

    public JFrame getMainFrame() {
        return mainFrame;
    }

    private void loadLocalData() {
        while (true) {
            File dataFile = findDatabaseFile();
            if (dataFile == null) {
                // Keine Daten in default Locations vorhanden
                return;
            }
            if (core.getCurrentCryptor() == null) {
                if (!createNewCryptor(false)) {
                    // Vorgang abgebrochen
                    return;
                }
            }
            try {
                core.loadDatabase(dataFile);
                loadedFile = dataFile;
                return;
            } catch (Exception e) {
                e.printStackTrace();
                showError(e);
                core.setCryptor(null);
            }
        }
    }

    /**
     * @return 'true' wenn alles fehlerfrei lief
     */
    private boolean downloadAndMergeData() {
        if (core.getSyncCredentials() == null) {
            // Nichts zu tun, aber kein Fehler
            return true;
        }
        if (core.getCurrentCryptor() == null) {
			/*
			 * Beim Sync Passwort mit Bestaetigung abfragen, weil beim falsch
			 * eingegebenem Passwort keine Fehlermeldung kommt sondern einfach
			 * nur leere Daten
			 */
            if (!createNewCryptor(true)) {
                // Vorgang abgebrochen
                return false;
            }
        }
        final AtomicReference<SyncResult> incomingChanges = new AtomicReference<SyncResult>(SyncResult.NoData);
        Callable<String> callable = new Callable<String>() {

            @Override
            public String call() throws Exception {
                // Mit neuesten Daten vom Sync-Account mergen
                System.out.println("Download data from " + core.getSyncCredentials().getEmailaddress());
                incomingChanges.set(core.syncDatabase(true));
                synced = true;
                return null;
            }
        };
        CallableTask<String> task = new CallableTask<String>(callable);
        WaitDialog dlg = new WaitDialog(getMainFrame(), "Download data", task, 0, 0);
        dlg.start();
        try {
            task.get();
            mainPanel.init();
            if (incomingChanges.get() == SyncResult.NoData) {
                showInfo("No sync data found on the server");
            } else if (!hasChanges && incomingChanges.get() == SyncResult.IncomingChanges) {
                setNeedSave(true);
				/*
				 * Wenn lokale Aenderungen nur von gerade runtergeladenen Daten
				 * kommen, dann die fusionierte Daten sofort lokal abspeichern
				 */
                setNeedSave(!localSaveData());
                return !hasChanges;
            }
            if (incomingChanges.get() == SyncResult.OutgoingChanges) {
				/*
				 * Es existieren lokale Daten die nicht auf dem sync-Server
				 * bekannt sind. Speicher-Flag setzen damit das Upload nicht
				 * vergessen wird
				 */
                setNeedSave(true);
            }

            return true;
        } catch (InterruptedException e) {
            e.printStackTrace();
        } catch (ExecutionException e) {
            e.printStackTrace();
            showError("Sync failed", e.getCause());
        }
        return false;
    }

    private void showInfo(String string) {
        JOptionPane.showMessageDialog(getMainFrame(), string, "", JOptionPane.INFORMATION_MESSAGE);
    }

    /**
     * @param withConfirmation
     * @return 'true' wenn kein Abbruch durch Benutzer
     */
    private boolean createNewCryptor(boolean withConfirmation) {
        char[] psw = inputPassphrase(withConfirmation, "Passphrase");
        if (psw == null) {
            return false;
        }
        CreateCryptorTask task = new CreateCryptorTask(psw);
        WaitDialog dlg = new WaitDialog(getMainFrame(), "Generate key", task, 0, 100);
        dlg.start();
        try {
            core.setCryptor(task.get());
        } catch (ExecutionException e) {
            e.getCause().printStackTrace();
            showError(e);
        } catch (InterruptedException e) {
            e.printStackTrace();
            return false;
        }
        Arrays.fill(psw, '*');
        return true;

    }

    /**
     * Speichert Daten lokal auf dem Datentraeger
     *
     * @return 'true' wenn alles fehlerfrei lief
     */
    private boolean localSaveData() {
        if (loadedFile == null) {
            loadedFile = fileToLoad;
        }
        File file = loadedFile;
        if (file == null) {
            file = new File(getProgrammLocationDir(), DATA_FILE_NAME);
        }
        try {
            System.out.println("Save to " + file.getAbsolutePath());
            core.saveDatabase(file);
            loadedFile = file;
        } catch (Exception e) {
            System.out.println("Save failed: " + e.getLocalizedMessage());
			/*
			 * Speichern fehlgeschlagen evt wegen schreibgeschutzten Ordner oder
			 * Datei.
			 */
            if (loadedFile != null) {
				/*
				 * Da von dieser Datei schon geladen wurde, mit einer
				 * Fehlermeldung abbrechen und nicht versuchen in eine
				 * alternative Lokation zu speichern
				 */
                showError(e);
                return false;
            }
            file = new File(SystemUtils.getUserHome(), DATA_FILE_NAME);
            try {
                System.out.println("Save to " + file.getAbsolutePath());
                core.saveDatabase(file);
                loadedFile = file;
            } catch (Exception e1) {
                System.out.println("Save failed: " + e.getLocalizedMessage());
                showError(e);
                return false;
            }
        }
        return true;
    }

    /**
     * Kombinierte Methode die Daten hochlaedt und dann lokal abspeichert.
     *
     * @return 'true' wenn alles fehlerfrei lief
     */
    private boolean saveDatabase() {
        if (core.getCurrentCryptor() == null) {
            if (!createNewCryptor(true)) {
                return false;
            }
        }
        if (core.getSyncCredentials() != null) {
            if (!synced) {
				/*
				 * Zuerst mit frischen Daten syncen. Sonst koennen beim
				 * Hochladen nicht gesyncte Aenderungen ueberschrieben werden
				 */
                downloadAndMergeData();
            }
            Callable<String> callable = new Callable<String>() {

                @Override
                public String call() throws Exception {
                    // Aktuelle Daten zum Sync-Account schicken
                    System.out.println("Upload data to " + core.getSyncCredentials().getEmailaddress());
                    core.save(core.getSyncCredentials());
                    return null;
                }
            };
            CallableTask<String> task = new CallableTask<String>(callable);
            WaitDialog dlg = new WaitDialog(getMainFrame(), "Upload data", task, 0, 0);
            dlg.start();
            try {
                task.get();
            } catch (InterruptedException e) {
                e.printStackTrace();
                return false;
            } catch (ExecutionException e) {
                e.printStackTrace();
                showError("Upload failed", e.getCause());
                return false;
            }
        }
        setNeedSave(!localSaveData());
        return !hasChanges;
    }

    private JMenuBar createMenuBar() {
        JMenuBar bar = new JMenuBar();
        JMenu menu = null;
		/*
		 * 'File' Menue
		 */
        menu = new JMenu("File");
        menu.setMnemonic(KeyEvent.VK_F);
        bar.add(menu);

        JMenuItem item = new JMenuItem("Save database");
        item.setAccelerator(KeyStroke.getKeyStroke("control S"));
        item.setMnemonic(KeyEvent.VK_S);
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                saveDatabase();
            }
        });
        menu.add(item);

        item = new JMenuItem("Download database");
        item.setMnemonic(KeyEvent.VK_L);
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                downloadAndMergeData();
            }
        });
        menu.add(item);

        item = new JMenuItem("Edit sync account");
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                editSyncAccount();
            }
        });
        menu.add(item);
        menu.add(new JSeparator());

        JMenu submenu = new JMenu("Import");
        menu.add(submenu);

        item = new JMenuItem("From CSV");
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                importCSV();
            }
        });
        submenu.add(item);

        submenu = new JMenu("Export");
        menu.add(submenu);

        item = new JMenuItem("As CSV");
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                exportCSV();
            }
        });
        submenu.add(item);
        item = new JMenuItem("Change passphrase");
        menu.add(item);
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                changePassword();
            }
        });

		/*
		 * 'Edit' Menue
		 */
        menu = new JMenu("Edit");
        menu.setMnemonic(KeyEvent.VK_E);
        bar.add(menu);
        item = menu.add(mainPanel.getNewEntryAction());
        item.setMnemonic(KeyEvent.VK_N);
        item = menu.add(mainPanel.getDeleteEntryAction());
        item.setMnemonic(KeyEvent.VK_D);

        menu.add(new JSeparator());

        menu = new JMenu("Tools");
        // item = new JMenuItem("Passwort generator");
        // menu.add(item);
        // item.addActionListener(new ActionListener() {
        //
        // @Override
        // public void actionPerformed(ActionEvent e) {
        // passGenerator.setVisible(false);
        // passGenerator.setLocationRelativeTo(getMainFrame());
        // passGenerator.setVisible(true);
        // }
        // });
        item = new JMenuItem("Screen keyboard");
        menu.add(item);
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                screenKeyboard.setLocationRelativeTo(getMainFrame());
                screenKeyboard.setVisible(true);

            }
        });
        item = new JMenuItem("File digester");
        menu.add(item);
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                digester.setLocationRelativeTo(getMainFrame());
                digester.setVisible(true);

            }
        });
        bar.add(menu);
		/*
		 * 'Help' Menue
		 */
        menu = new JMenu("Help");
        menu.setMnemonic(KeyEvent.VK_H);
        bar.add(menu);

        item = new JMenuItem("Performance test");
        menu.add(item);
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                measurePerformance();
            }
        });
        item = new JMenuItem("System info");
        menu.add(item);
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                showSystemInfo();
            }
        });
        item = new JMenuItem("About");
        menu.add(item);
        item.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                String text = "<html>Ultracipher 6.1<br>(C) Copyright 2015 Paul Burlov<br><br>"
                        + "Encryption strength: 768Bit (6 x 128Bit keys)<br>Cipher cascade: AES/Twofish/Serpent/CAST6/SEED/Camellia"
                        + "<br>Encryption mode: Two pass CBC"
                        + "<br>Key derivation algorithm: SCrypt with N=2^14,P=8,R=1<br><br> "
                        + "This product includes software developed by the<br>"
                        + "<ul><li>Apache Software Foundation "
                        + "<a href='http://www.apache.org'>http://www.apache.org</a>"
                        + "<li>Legion of the Bouncy Castle <a href='http://bouncycastle.org/'>http://bouncycastle.org</a>"
                        + "<li>Project SwingX" + "<li>Bytecode Pty Ltd." + "</ul></html>";
                JOptionPane.showMessageDialog(getMainFrame(), text, "", JOptionPane.INFORMATION_MESSAGE, getAppIcon());
            }
        });
        bar.add(Box.createHorizontalGlue());
        menu = new JMenu("Keyboard");
        ButtonGroup group = new ButtonGroup();
        JRadioButtonMenuItem radioitem = new JRadioButtonMenuItem("System");
        radioitem.setSelected(true);
        group.add(radioitem);
        radioitem.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                translator.resetMapping();
            }
        });
        menu.add(radioitem);
        radioitem = new JRadioButtonMenuItem("Futhark runes");
        group.add(radioitem);
        radioitem.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                translator.initForFuthark();
            }
        });
        menu.add(radioitem);
        radioitem = new JRadioButtonMenuItem("Anglo-Saxon runes");
        group.add(radioitem);
        radioitem.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                translator.initForAngloSaxon();
            }
        });
        menu.add(radioitem);
        bar.add(menu);
        // bar.add(Box.createHorizontalGlue());
        // bar.add(new PassGeneratorPanel());
        return bar;
    }

    protected void measurePerformance() {
        SwingWorker<Double, Object> task = new SwingWorker<Double, Object>() {

            @Override
            protected Double doInBackground() throws Exception {
                Ultracipher.measurePerformance();// Warm up
                return Ultracipher.measurePerformance();
            }
        };
        WaitDialog dlg = new WaitDialog(getMainFrame(), "Measure performance", task, 0, 0);
        dlg.start();
        try {
            JOptionPane.showMessageDialog(getMainFrame(),
                    String.format("Performance index (bigger is better): %.3f", task.get()));
        } catch (Exception e) {
            e.printStackTrace();
            showError(e);
        }
    }

    private void editSyncAccount() {
        SyncAccountSettingsDialog dlg = new SyncAccountSettingsDialog(this.getMainFrame(),
                core.getSupportedEmailSyncDomains(), core.getSyncCredentials());
        dlg.setLocationRelativeTo(getMainFrame());
        dlg.setVisible(true);
        EmailCredentials creds = dlg.getEmailCredentials();
        if (creds == null || ObjectUtils.equals(creds, core.getSyncCredentials())) {
            // Nix wurde gaendert
            return;
        }
        if (StringUtils.isBlank(creds.getEmailaddress())) {
            // Benutzer hat die Settings geloescht
            core.setSyncCredentials(null);
            updateNeedSave(true);
        } else {
            core.setSyncCredentials(creds);
			/*
			 * gleich versuchen mit geaendertem Sync-Account zu mergen
			 */
            if (downloadAndMergeData()) {
                // Sync war erfolgreich
                if (!hasChanges) {
					/*
					 * Wenn sonst keine Aenderungen, dann die neue Account-Daten
					 * gleich lokal speichern wenn die beim Sync noch nicht
					 * lokal gespeichert wurden
					 */
                    setNeedSave(!localSaveData());
                }
            } else {
				/*
				 * wenn sync fehlgeschlagen, dann nur lokale Aenderung
				 * signalisieren. Benutzer soll dann selbst entscheiden ob er
				 * die Account-Aenderungen abspeichern will
				 */
                setNeedSave(true);
            }
        }
    }

    public File chooseFile(boolean forSave) {
        JFileChooser chooser = new JFileChooser();
        chooser.setFileSelectionMode(JFileChooser.FILES_ONLY);
        int ret = forSave ? chooser.showSaveDialog(getMainFrame()) : chooser.showOpenDialog(getMainFrame());
        if (JFileChooser.APPROVE_OPTION == ret) {
            File file = chooser.getSelectedFile();
            return file;
        }
        return null;
    }

    private void importCSV() {
        File file = chooseFile(false);
        if (file == null) {
            return;
        }
        CSVSettingsDialog dlg = new CSVSettingsDialog(getMainFrame());
        dlg.setLocationRelativeTo(getMainFrame());
        dlg.setVisible(true);
        dlg.dispose();
        CSVSettings settings = dlg.getSettings();
        if (settings == null) {
            return;
        }
        try {
            String csv = FileUtils.readFileToString(file, "UTF-8");
            core.importFromCSV(csv, settings);
            setNeedSave(true);
            mainPanel.init();
        } catch (Exception e) {
            e.printStackTrace();
            showError("Import from CSV failed", e);
        }
    }

    private void exportCSV() {
        File file = chooseFile(true);
        if (file == null) {
            return;
        }
        CSVSettingsDialog dlg = new CSVSettingsDialog(getMainFrame());
        dlg.setLocationRelativeTo(getMainFrame());
        dlg.setVisible(true);
        dlg.dispose();
        CSVSettings settings = dlg.getSettings();
        if (settings == null) {
            return;
        }
        try {
            String csv = core.exportAsCSV(settings);
            FileUtils.write(file, csv, "UTF-8");
        } catch (Exception e) {
            e.printStackTrace();
            showError("Export to CSV failed,", e);
        }
    }

    private void changePassword() {
        boolean change = createNewCryptor(true);
        updateNeedSave(change);
    }

    /**
     * Zeigt dem Benutzer Passworteingabedialog.
     *
     * @param withConfirm 'true' wenn Eingabe mit einem redundanten Eingabefeld
     *                    validiert werden soll
     * @return eingegebene Passphrase oder null falls abgebrochen wurde
     */
    public char[] inputPassphrase(boolean withConfirm, String header) {
        PasswordDialog dlg = new PasswordDialog(getMainFrame(), withConfirm, header);
        dlg.setLocationRelativeTo(getMainFrame());
        dlg.setVisible(true);
        return dlg.getPassphrase();
    }

    public MainPanel getMainPanel() {
        return mainPanel;
    }

    public void showError(String msg, Throwable e) {
        StringWriter swriter = new StringWriter();
        PrintWriter pwriter = new PrintWriter(swriter, true);
        pwriter.println("<pre>");
        e.printStackTrace(pwriter);

        swriter.append("\n\n======== System properties =======\n");
        swriter.append(createSystemInfo());
        pwriter.println("</pre>");
        pwriter.flush();
        ErrorInfo info = new ErrorInfo("Error", msg, swriter.toString(), null, e, null, null);
        JXErrorPane.showDialog(getMainFrame(), info);
    }

    public void showError(Throwable e) {
        showError(e.getMessage(), e);
    }

    public void showSystemInfo() {
        JOptionPane.showMessageDialog(getMainFrame(), createSystemInfo(), "System info", JOptionPane.INFORMATION_MESSAGE);
    }

    public Database getDatabase() {
        return core.getDatabase();
    }

    public boolean isNeedSave() {
        return hasChanges;
    }

    public void setNeedSave(boolean needSave) {
        this.hasChanges = needSave;
        SwingUtilities.invokeLater(new Runnable() {

            @Override
            public void run() {
                getMainFrame().setTitle(getFrameTitle());
            }
        });
    }

    public void updateNeedSave(boolean localSave) {
        setNeedSave(isNeedSave() || localSave);
    }

    /**
     * Methode versucht zuletzt gespeicherte Datei zu finden. Zuerst wird in dem
     * gleichem Ordner gesucht wo die JAR-Datei selbst liegt. Als Ausweichstelle
     * wird in dem Home-Ordner des Benutzers gesucht
     *
     * @return
     */
    private File findDatabaseFile() {
        if (fileToLoad != null) {
			/*
			 * Zieldatei, die als Programmargument mitgegeben wurde hat oberstes
			 * Prioritaet. Alle Dateien werden ignoriert.
			 */
            if (fileToLoad.exists() && fileToLoad.canRead()) {
                return fileToLoad;
            }
            return null;
        }
        File dataFile = null;
        File runningDir = getProgrammLocationDir();
        if (runningDir != null) {
            dataFile = new File(runningDir, DATA_FILE_NAME);
            if (dataFile.exists() && dataFile.canRead()) {
                return dataFile;
            }
        }
        File homeDir = SystemUtils.getUserHome();
        dataFile = new File(homeDir, DATA_FILE_NAME);
        if (dataFile.exists() && dataFile.canRead()) {
            return dataFile;
        }
        return null;
    }

    /**
     * @return Ordern wo die JAR-Datei liegt oder null wegen irgendwelchen
     * Fehler
     */
    private File getProgrammLocationDir() {
        try {
            return new File(getClass().getProtectionDomain().getCodeSource().getLocation().getPath()).getParentFile();
        } catch (Exception e) {
            System.out.println(e);
            return null;
        }
    }

}
