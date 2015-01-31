package de.burlov.ultracipher.core;

public class KeyGenPerformanceLevel {
    /**
     * 4MB  Speicherverbrauch
     */
    public static final KeyGenPerformanceLevel VERY_LOW = new KeyGenPerformanceLevel(4096, 4, 1);
    /**
     * 16MB  Speicherverbrauch
     */
    public static final KeyGenPerformanceLevel DEFAULT = new KeyGenPerformanceLevel(16384, 8, 1);
    /**
     * 32MB  Speicherverbrauch
     */
    public static final KeyGenPerformanceLevel MIDDLE = new KeyGenPerformanceLevel(32768, 8, 1);
    /**
     * 67MB  Speicherverbrauch
     */
    public static final KeyGenPerformanceLevel HIGH = new KeyGenPerformanceLevel(65536, 8, 1);
    /**
     * 134MB  Speicherverbrauch
     */
    public static final KeyGenPerformanceLevel VERY_HIGH = new KeyGenPerformanceLevel(131072, 8, 1);
    int N;
    int p;
    int r;

    public KeyGenPerformanceLevel(int n, int p, int r) {
        N = n;
        this.p = p;
        this.r = r;
    }
}
