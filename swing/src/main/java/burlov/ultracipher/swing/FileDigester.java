package burlov.ultracipher.swing;

import org.apache.commons.io.FileUtils;
import org.apache.commons.io.IOUtils;
import org.apache.commons.io.output.NullOutputStream;

import java.awt.BorderLayout;
import java.awt.HeadlessException;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;
import java.io.File;
import java.io.InputStream;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ExecutionException;

import javax.swing.JButton;
import javax.swing.JFileChooser;
import javax.swing.JFrame;
import javax.swing.JScrollPane;
import javax.swing.JTextArea;
import javax.swing.SwingWorker;

import de.burlov.ultracipher.core.bouncycastle.crypto.Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.MD5Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.RIPEMD128Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.RIPEMD160Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.RIPEMD256Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.SHA1Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.SHA224Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.SHA256Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.SHA384Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.SHA512Digest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.TigerDigest;
import de.burlov.ultracipher.core.bouncycastle.crypto.digests.WhirlpoolDigest;
import de.burlov.ultracipher.core.bouncycastle.crypto.io.DigestInputStream;
import de.burlov.ultracipher.core.bouncycastle.util.encoders.Hex;

public class FileDigester extends JFrame {

    /**
     *
     */
    private static final long serialVersionUID = 1L;
    private JTextArea results = new JTextArea(20, 80);
    private List<Digest> digests = Arrays.asList(new SHA1Digest(), new SHA224Digest(), new SHA256Digest(), new SHA384Digest(), new SHA512Digest(),
            new RIPEMD128Digest(), new RIPEMD160Digest(), new RIPEMD256Digest(), new TigerDigest(), new WhirlpoolDigest(), (Digest) new MD5Digest());

    public FileDigester() throws HeadlessException {
        super();
        this.setTitle("File digester");
        JButton button = new JButton("Choose file");
        button.addActionListener(new ActionListener() {

            @Override
            public void actionPerformed(ActionEvent e) {
                compute(chooseFile());
            }
        });

        this.getContentPane().add(button, BorderLayout.NORTH);
        results.setEditable(false);
        TextPopup.installTextPopupMenu(results);
        JScrollPane scroll = new JScrollPane(results);

        this.getContentPane().add(scroll, BorderLayout.CENTER);
        this.setSize(results.getPreferredSize());
        this.pack();
    }

    private File chooseFile() {
        JFileChooser chooser = new JFileChooser();
        chooser.setFileSelectionMode(JFileChooser.FILES_ONLY);
        if (JFileChooser.APPROVE_OPTION == chooser.showOpenDialog(this)) {
            File file = chooser.getSelectedFile();
            return file;
        }
        return null;
    }

    private void compute(final File file) {
        if (file == null) {
            return;
        }
        SwingWorker<String, Object> call = new SwingWorker<String, Object>() {

            @Override
            protected String doInBackground() throws Exception {
                InputStream in = FileUtils.openInputStream(file);
                try {
                    for (Digest dig : digests) {
                        dig.reset();
                        in = new DigestInputStream(in, dig);
                    }
                    long length = file.length() + 1;
                    byte[] buf = new byte[100000];
                    long counter = 0;
                    int i = 0;
                    while ((i = in.read(buf)) > -1) {
                        counter += i;
                        int prog = (int) Math.min(counter * 100 / length, 100);
                        setProgress(prog);
                    }
                    IOUtils.copy(in, new NullOutputStream());
                    StringBuffer sb = new StringBuffer();
                    for (Digest dig : digests) {
                        buf = new byte[dig.getDigestSize()];
                        dig.doFinal(buf, 0);
                        sb.append(dig.getAlgorithmName());
                        sb.append(": ");
                        sb.append(new String(Hex.encode(buf)));
                        sb.append('\n');
                    }
                    return sb.toString();
                } finally {
                    IOUtils.closeQuietly(in);
                }
            }
        };
        WaitDialog dlg = new WaitDialog(this, "Computing", call, 0, 100);
        dlg.start();
        try {
            results.setText(call.get());
        } catch (InterruptedException e) {
            e.printStackTrace();
            results.setText(e.toString());
        } catch (ExecutionException e) {
            e.printStackTrace();
            results.setText(e.getCause().toString());
        }
    }

}
