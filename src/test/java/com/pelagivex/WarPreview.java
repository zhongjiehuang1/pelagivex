package com.pelagivex;

import java.nio.file.Files;
import java.nio.file.Path;
import org.apache.catalina.startup.Tomcat;

/** Local production-WAR preview for packaging and Servlet discovery checks. */
public final class WarPreview {
    public static void main(String[] args) throws Exception {
        Path project = Path.of("").toAbsolutePath();
        Path runtime = project.resolve(".tmp/war-preview");
        Files.createDirectories(runtime);
        Files.createDirectories(runtime.resolve("webapps"));
        Tomcat tomcat = new Tomcat();
        tomcat.setBaseDir(runtime.toString());
        tomcat.setPort(args.length > 0 ? Integer.parseInt(args[0]) : 8770);
        tomcat.getConnector().setProperty("address", "127.0.0.1");
        tomcat.addWebapp("", project.resolve("target/Pelagivex.war").toString());
        tomcat.start();
        System.out.println("WAR preview: http://127.0.0.1:" + tomcat.getConnector().getLocalPort() + "/");
        tomcat.getServer().await();
    }
}
