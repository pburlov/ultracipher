/*
 * Copyright © 2001,2012 by Paul Burlov. All Rights Reserved.
 * Created Jun 3, 2012
 */
package de.burlov.ultracipher.core.mail;

import org.apache.commons.lang3.StringUtils;
import org.json.simple.JSONObject;
import org.json.simple.JSONValue;

import java.io.Serializable;
import java.util.Map;

public class EmailCredentials implements Serializable {
    private static final String KEY_PASSWORD = "password";
    private static final String KEY_ADDRESS = "address";
    /**
     *
     */
    private static final long serialVersionUID = 1L;
    private final String emailaddress;
    private final String password;

    public EmailCredentials(String emailaddress, String password) {
        super();
        if (emailaddress == null || password == null) {
            throw new IllegalArgumentException("null parameter");
        }
        this.emailaddress = emailaddress;
        this.password = password;
    }

    static public EmailCredentials importJson(String json) throws Exception {
        Map<String, String> map = (Map<String, String>) JSONValue.parse(json);
        String address = map.get(KEY_ADDRESS);
        String password = map.get(KEY_PASSWORD);
        return new EmailCredentials(address, password);
    }

    public String getEmailaddress() {
        return emailaddress;
    }

    public String getPassword() {
        return password;
    }

    /**
     * @return Host Teil der Email-Adresse ohne '@'
     */
    public String getDomainPart() {
        return StringUtils.substringAfterLast(emailaddress, "@");
    }

    /**
     * @return Teil der Email-Adresse das vor '@' steht
     */
    public String getUserPart() {
        return StringUtils.substringBeforeLast(emailaddress, "@");
    }

    public String exportJson() {
        JSONObject jo = new JSONObject();
        jo.put(KEY_ADDRESS, emailaddress);
        jo.put(KEY_PASSWORD, password);
        return jo.toJSONString();
    }

    @Override
    public int hashCode() {
        final int prime = 31;
        int result = 1;
        result = prime * result + ((emailaddress == null) ? 0 : emailaddress.hashCode());
        result = prime * result + ((password == null) ? 0 : password.hashCode());
        return result;
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj)
            return true;
        if (obj == null)
            return false;
        if (getClass() != obj.getClass())
            return false;
        EmailCredentials other = (EmailCredentials) obj;
        if (emailaddress == null) {
            if (other.emailaddress != null)
                return false;
        } else if (!emailaddress.equals(other.emailaddress))
            return false;
        if (password == null) {
            if (other.password != null)
                return false;
        } else if (!password.equals(other.password))
            return false;
        return true;
    }

    @Override
    public String toString() {
        return password + ":" + emailaddress;
    }
}
