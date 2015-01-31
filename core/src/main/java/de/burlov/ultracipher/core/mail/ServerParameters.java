/*
 	Copyright (C) 2009 Paul Burlov
 	
 	
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
package de.burlov.ultracipher.core.mail;

import java.io.Serializable;

/**
 * @author paul
 */
public class ServerParameters implements Serializable {
    public static final int DEFAULT_POP3_PORT = 110;
    public static final int DEFAULT_SMTP_PORT = 25;
    /**
     *
     */
    private static final long serialVersionUID = 1L;
    private String host;
    private int port;
    private String username;
    private String password;
    private boolean useSSL;

    protected ServerParameters() {
        super();
    }

    public ServerParameters(String host, int port, String username, String password, boolean useSSL) {
        super();
        this.host = host;
        this.port = port;
        this.username = username;
        this.password = password;
        this.useSSL = useSSL;
    }

    public String getHost() {
        return host;
    }

    public void setHost(String host) {
        this.host = host;
    }

    public int getPort() {
        return port;
    }

    public void setPort(int port) {
        this.port = port;
    }

    public String getUsername() {
        return username;
    }

    public void setUsername(String username) {
        this.username = username;
    }

    public String getPassword() {
        return password;
    }

    public void setPassword(String password) {
        this.password = password;
    }

    public boolean isUseSSL() {
        return useSSL;
    }

    public void setUseSSL(boolean useSSL) {
        this.useSSL = useSSL;
    }

    @Override
    public String toString() {
        return username + "@" + host + ":" + port;
    }

    @Override
    public int hashCode() {
        final int prime = 31;
        int result = 1;
        result = prime * result + ((host == null) ? 0 : host.hashCode());
        result = prime * result + ((password == null) ? 0 : password.hashCode());
        result = prime * result + port;
        result = prime * result + (useSSL ? 1231 : 1237);
        result = prime * result + ((username == null) ? 0 : username.hashCode());
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
        ServerParameters other = (ServerParameters) obj;
        if (host == null) {
            if (other.host != null)
                return false;
        } else if (!host.equals(other.host))
            return false;
        if (password == null) {
            if (other.password != null)
                return false;
        } else if (!password.equals(other.password))
            return false;
        if (port != other.port)
            return false;
        if (useSSL != other.useSSL)
            return false;
        if (username == null) {
            if (other.username != null)
                return false;
        } else if (!username.equals(other.username))
            return false;
        return true;
    }

}
