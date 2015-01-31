/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 3, 2012
 */
package de.burlov.ultracipher.core.mail;

import org.apache.commons.io.IOUtils;
import org.apache.commons.lang3.StringUtils;
import org.apache.commons.net.PrintCommandListener;
import org.apache.commons.net.imap.AuthenticatingIMAPClient;
import org.apache.commons.net.pop3.POP3Client;
import org.apache.commons.net.pop3.POP3MessageInfo;
import org.apache.commons.net.pop3.POP3SClient;
import org.apache.commons.net.smtp.SMTPReply;
import org.apache.commons.net.smtp.SimpleSMTPHeader;
import org.apache.commons.net.util.Base64;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.PrintWriter;
import java.io.Reader;
import java.io.Writer;
import java.text.DateFormat;
import java.text.SimpleDateFormat;
import java.util.Calendar;
import java.util.Collection;
import java.util.Date;
import java.util.GregorianCalendar;
import java.util.Locale;
import java.util.SortedMap;
import java.util.SortedSet;
import java.util.TreeMap;
import java.util.TreeSet;

import de.burlov.ultracipher.core.ICryptor;
import de.burlov.ultracipher.core.mail.AuthenticatingSMTPClient.AUTH_METHOD;

class MailHandler {
    protected static final String TIMESTAMP_HEADER = "X-ULTRACIPHER-TIMESTAMP";
    protected static final String HMAC_HEADER = "X-ULTRACIPHER-HMAC";
    private PrintWriter debugWriter;

    protected MailHandler() {
        super();
    }

    static private String formatDate(Date date) {
//		SimpleDateFormat format = new SimpleDateFormat("dd-MMM-yyyy HH:mm:ss Z");
        SimpleDateFormat format = new SimpleDateFormat("dd-MMM-yyyy", Locale.US);
        return format.format(date);
    }

    static SortedSet<Integer> parseSearchResults(String[] lines) {
        TreeSet<Integer> ret = new TreeSet<Integer>();
        if (lines == null) {
            return ret;
        }
        for (String line : lines) {
            String msgNumbers = StringUtils.substringAfterLast(line, "SEARCH");
            String[] numbers = msgNumbers.split("\\s+");
            for (String n : numbers) {
                try {
                    ret.add(Integer.parseInt(n));
                } catch (Exception e) {
                    // ignore
                }
            }
        }
        return ret;
    }

    /**
     * @param ids
     * @return Liste mit Nummern durch Leerzeichen getrennt
     */
    static private String toIdList(Collection<Integer> ids) {
        StringBuilder sb = new StringBuilder();
        for (Integer id : ids) {
            sb.append(id.intValue());
            sb.append(' ');
        }
        return sb.toString();
    }

    public void setDebugWriter(PrintWriter writer) {
        this.debugWriter = writer;
    }

    private String computeMarkerString(ICryptor cryptor) throws Exception {
        return Base64.encodeBase64URLSafeString(cryptor.hmac(HMAC_HEADER.getBytes("US-ASCII")));
    }

    protected void sendData(ServerParameters smtpParams, String sender, Collection<String> recipients, String data,
                            ICryptor cryptor) throws Exception {
        if (recipients.isEmpty()) {
            throw new IllegalArgumentException("no recipients");
        }
        AuthenticatingSMTPClient client;
        try {
            client = new AuthenticatingSMTPClient(smtpParams.isUseSSL());
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
        try {
            if (debugWriter != null) {
                client.addProtocolCommandListener(new PrintCommandListener(debugWriter, true));
            }
            client.setConnectTimeout(10000);
            client.connect(smtpParams.getHost(), smtpParams.getPort());
            if (!SMTPReply.isPositiveCompletion(client.getReplyCode())) {
                client.disconnect();
                throw new IOException("SMTP server refused connection: " + client.getReplyString());
            }
            client.ehlo("localhost");
            try {
                if (!client.auth(AUTH_METHOD.PLAIN, smtpParams.getUsername(), smtpParams.getPassword())) {
                    throw new IOException("Login failed: " + client.getReplyString());
                }
            } catch (Exception e) {
                throw new IOException("login failed: " + e);
            }
            client.setSender(sender);
            for (String rec : recipients) {
                client.addRecipient(rec);
            }
            SimpleSMTPHeader header = new SimpleSMTPHeader(sender, recipients.iterator().next(), "UltraCipher "
                    + DateFormat.getDateTimeInstance().format(new Date()));
            header.addHeaderField(TIMESTAMP_HEADER, Long.toHexString(System.currentTimeMillis()));
            header.addHeaderField(HMAC_HEADER, computeMarkerString(cryptor));
            Writer writer = client.sendMessageData();

            if (writer != null) {
                writer.write(header.toString());
                writer.write(data);
                writer.close();
                client.completePendingCommand();
            }
            client.logout();
            client.disconnect();
        } finally {
            client.disconnect();
        }
    }

    protected String retrieveDataIMAP(ServerParameters imapParams, ICryptor cryptor) throws Exception {
        AuthenticatingIMAPClient imap = new AuthenticatingIMAPClient(true);
        imap.setDefaultTimeout(10000);
        String ret = null;
        try {
            if (debugWriter != null) {
                imap.addProtocolCommandListener(new PrintCommandListener(debugWriter, true));
            }
            imap.connect(imapParams.getHost(), imapParams.getPort());
            imap.capability();
            if (!imap.login(imapParams.getUsername(), imapParams.getPassword())) {
                throw new IOException(imap.getReplyString());
            }
            if (!imap.select("INBOX")) {
                throw new IOException("Select INBOX failed: " + imap.getReplyString());
            }
            logStream(imap.getReplyStrings());
            GregorianCalendar cal = new GregorianCalendar();
            cal.add(Calendar.YEAR, -1);
            if (!imap.search("HEADER " + HMAC_HEADER + " \"" + computeMarkerString(cryptor) + "\" SINCE " + formatDate(cal.getTime()))) {
                throw new IOException("IMAP Search command failed: " + imap.getReplyString());
            }
            // imap.uid("SEARCH","HEADER "+TIMESTAMP_HEADER + " \"\"");
            SortedSet<Integer> msgNumbers = parseSearchResults(imap.getReplyStrings());
            if (msgNumbers.size() > 0) {
                Integer lastNumber = msgNumbers.last();
                if (!imap.fetch(lastNumber.toString(), "BODY[TEXT]")) {
                    throw new IOException("IMAP Fetch command failed: " + imap.getReplyString());
                }
                ret = imap.getReplyString();
            }
            imap.logout();
            imap.disconnect();
        } finally {
            imap.disconnect();
        }
        return ret;
    }

    private void logStream(String[] lines) {
        if (lines == null || debugWriter == null) {
            return;
        }
        for (String str : lines) {
            debugWriter.println(str);
        }
    }

    protected String retrieveDataPop3(ServerParameters pop3Params, boolean deleteSpam) throws IOException {
        POP3Client pop3 = new POP3Client();
        if (pop3Params.isUseSSL()) {
            pop3 = new POP3SClient(true);
        }
        pop3.setDefaultTimeout(10000);
        try {
            if (debugWriter != null) {
                pop3.addProtocolCommandListener(new PrintCommandListener(debugWriter, true));
            }
            pop3.connect(pop3Params.getHost(), pop3Params.getPort());
            if (!pop3.login(pop3Params.getUsername(), pop3Params.getPassword())) {
                throw new IOException("Login failed: " + pop3.getReplyString());
            }
            SortedMap<Long, POP3MessageInfo> dataMessages = findDataMessages(pop3, deleteSpam);
            if (dataMessages.isEmpty()) {
                pop3.logout();
                debugWriter.println("No data messages found");
                return null;
            }
            POP3MessageInfo latestMessage = dataMessages.remove(dataMessages.lastKey());
            Reader msgReader = pop3.retrieveMessage(latestMessage.number);
            String ret = IOUtils.toString(msgReader);

			/*
             * Restlichen alten Nachrichten loeschen
			 */
            for (POP3MessageInfo msg : dataMessages.values()) {
                debugWriter.println("delete message " + msg.number);
                pop3.deleteMessage(msg.number);
            }
            pop3.logout();
            pop3.disconnect();
            return ret;
        } finally {
            pop3.disconnect();
        }

    }

    private SortedMap<Long, POP3MessageInfo> findDataMessages(POP3Client pop3, boolean deleteSpam) throws IOException {
        SortedMap<Long, POP3MessageInfo> ret = new TreeMap<Long, POP3MessageInfo>();
        POP3MessageInfo[] messages = pop3.listMessages();
        if (messages == null) {
            throw new IOException("List command failed: " + pop3.getReplyString());
        }
        for (POP3MessageInfo msginfo : messages) {
            BufferedReader reader = (BufferedReader) pop3.retrieveMessageTop(msginfo.number, 0);
            if (reader == null) {
                throw new IOException("Could not retrieve message header.");
            }
            Long readedTimestamp = readTimestamp(reader);
            if (readedTimestamp != null) {
                ret.put(readedTimestamp, msginfo);
            }
            if (deleteSpam && readedTimestamp == null) {
                /*
				 * Alle nicht erkannte Nachrichten loeschen
				 */
                pop3.deleteMessage(msginfo.number);
            }
        }
        return ret;
    }

    private Long readTimestamp(BufferedReader reader) throws IOException {
        String line;
        String timestamp = null;
        while ((line = reader.readLine()) != null) {
            String lower = StringUtils.trimToEmpty(line);
            if (lower.startsWith(TIMESTAMP_HEADER)) {
                timestamp = StringUtils.trimToEmpty(StringUtils.substringAfter(line, TIMESTAMP_HEADER + ":"));
            }
        }
        if (timestamp == null) {
            return null;
        }
        try {
            return Long.parseLong(timestamp, 16);
        } catch (Exception e) {
            return null;
        }
    }
}
