package com.pelagivex;

import java.nio.file.Files;
import java.nio.file.Path;
import org.apache.catalina.Context;
import org.apache.catalina.Wrapper;
import org.apache.catalina.servlets.DefaultServlet;
import org.apache.catalina.startup.Tomcat;

/** Local-only preview launcher: binds to loopback and keeps runtime files in the checkout. */
public final class LocalServer {
    public static void main(String[] args) throws Exception {
        Path project = Path.of("").toAbsolutePath();
        Path runtime = project.resolve(".tmp/tomcat");
        Files.createDirectories(runtime);
        Tomcat tomcat = new Tomcat();
        tomcat.setBaseDir(runtime.toString());
        tomcat.setPort(args.length > 0 ? Integer.parseInt(args[0]) : 8768);
        tomcat.getConnector().setProperty("address", "127.0.0.1");
        Context context = tomcat.addContext("", project.resolve("web").toString());
        context.addWelcomeFile("index.html");
        context.addMimeMapping("html", "text/html");
        context.addMimeMapping("css", "text/css");
        context.addMimeMapping("js", "application/javascript");
        context.addMimeMapping("png", "image/png");
        context.addMimeMapping("jpg", "image/jpeg");
        context.addMimeMapping("svg", "image/svg+xml");
        Wrapper api = Tomcat.addServlet(context, "api", new ApiServlet());
        api.setMultipartConfigElement(ApiServlet.multipartConfig(runtime.toString()));
        api.setLoadOnStartup(1);
        context.addServletMappingDecoded("/api/*", "api");
        Tomcat.addServlet(context, "default", new DefaultServlet());
        context.addServletMappingDecoded("/", "default");
        tomcat.start();
        System.out.println("Pelagivex local preview: http://127.0.0.1:" + tomcat.getConnector().getLocalPort() + "/");
        tomcat.getServer().await();
    }
}
