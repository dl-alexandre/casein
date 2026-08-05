using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

internal static class Program
{
    private const string ManifestUrl = "__CASEIN_MANIFEST_URL__";
    private const string ModulusBase64 = "__CASEIN_RSA_MODULUS__";
    private const string ExponentBase64 = "__CASEIN_RSA_EXPONENT__";
    private const int MaxManifestBytes = 1024 * 1024;
    private const long MaxArtifactBytes = 2L * 1024 * 1024 * 1024;

    private sealed class Artifact
    {
        public string app { get; set; }
        public string version { get; set; }
        public string revision { get; set; }
        public string profile { get; set; }
        public string repo_adapter { get; set; }
        public string target { get; set; }
        public string url { get; set; }
        public string sha256 { get; set; }
        public long size { get; set; }
        public int min_installer_metadata_version { get; set; }
    }

    private sealed class Manifest
    {
        public int manifest_version { get; set; }
        public string channel { get; set; }
        public Artifact[] artifacts { get; set; }
    }

    private sealed class ReleaseMetadata
    {
        public string revision { get; set; }
        public string profile { get; set; }
        public string repo_adapter { get; set; }
        public string target { get; set; }
    }

    public static int Main(string[] args)
    {
        try
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            if (args.Length == 4 && args[0] == "--verify-only" &&
                Environment.GetEnvironmentVariable("CASEIN_BOOTSTRAP_TEST_MODE") == "1")
            {
                byte[] manifestBytes = File.ReadAllBytes(args[1]);
                byte[] signatureBytes = ReadSignature(File.ReadAllText(args[2], Encoding.ASCII));
                VerifyManifestSignature(manifestBytes, signatureBytes);
                Manifest manifest = ParseManifest(manifestBytes);
                Artifact artifact = SelectArtifact(manifest, new Uri(ManifestUrl));
                VerifyArtifactFile(args[3], artifact);
                Console.WriteLine("Casein development channel verification passed.");
                return 0;
            }

            Uri manifestUri = RequireSecureUri(ManifestUrl, null);
            Console.WriteLine("Checking the Casein development channel...");
            byte[] remoteManifest = DownloadSmall(manifestUri, MaxManifestBytes);
            byte[] remoteSignature = ReadSignature(Encoding.ASCII.GetString(
                DownloadSmall(new Uri(manifestUri.AbsoluteUri + ".sig"), 64 * 1024)));
            VerifyManifestSignature(remoteManifest, remoteSignature);
            Manifest parsed = ParseManifest(remoteManifest);
            Artifact selected = SelectArtifact(parsed, manifestUri);

            string installedRevision = ReadInstalledRevision();
            if (String.Equals(installedRevision, selected.revision, StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine("Casein is already current at " + selected.revision.Substring(0, 7) + ".");
                return 0;
            }

            string stage = Path.Combine(Path.GetTempPath(), "C", selected.revision.Substring(0, 7));
            RecreateSafeStage(stage);
            string archive = Path.Combine(stage, "casein.zip");
            Console.WriteLine("Downloading Casein " + selected.revision.Substring(0, 7) + "...");
            DownloadArtifact(new Uri(selected.url), archive, selected);
            string packageRoot = Path.Combine(stage, "p");
            ExtractSafely(archive, packageRoot);
            ValidatePackage(packageRoot, selected);
            Install(packageRoot);
            Console.WriteLine("Casein installed successfully.");
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine("Casein setup failed: " + exception.Message);
            Console.Error.WriteLine("No unverified update was installed.");
            return 1;
        }
    }

    private static Uri RequireSecureUri(string value, Uri sameOrigin)
    {
        Uri uri;
        if (!Uri.TryCreate(value, UriKind.Absolute, out uri) || uri.Scheme != Uri.UriSchemeHttps ||
            !String.IsNullOrEmpty(uri.UserInfo) || !String.IsNullOrEmpty(uri.Query) ||
            !String.IsNullOrEmpty(uri.Fragment))
            throw new InvalidDataException("Development update URLs must be credential-free HTTPS URLs.");
        if (sameOrigin != null && !String.Equals(uri.Scheme + "://" + uri.Authority,
            sameOrigin.Scheme + "://" + sameOrigin.Authority, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The update artifact must use the manifest origin.");
        return uri;
    }

    private static byte[] DownloadSmall(Uri uri, int limit)
    {
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
        request.AllowAutoRedirect = false;
        request.Timeout = 30000;
        request.ReadWriteTimeout = 30000;
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        {
            if (response.StatusCode != HttpStatusCode.OK) throw new IOException("Update server returned " + response.StatusCode + ".");
            if (response.ContentLength > limit) throw new InvalidDataException("Update metadata is too large.");
            using (Stream input = response.GetResponseStream())
            using (MemoryStream output = new MemoryStream())
            {
                CopyWithLimit(input, output, limit);
                return output.ToArray();
            }
        }
    }

    private static void CopyWithLimit(Stream input, Stream output, long limit)
    {
        byte[] buffer = new byte[1024 * 128];
        long total = 0;
        int read;
        while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
        {
            total += read;
            if (total > limit) throw new InvalidDataException("Downloaded content exceeds its allowed size.");
            output.Write(buffer, 0, read);
        }
    }

    private static byte[] ReadSignature(string encoded)
    {
        try { return Convert.FromBase64String(encoded.Trim()); }
        catch (FormatException) { throw new InvalidDataException("The development manifest signature is invalid."); }
    }

    private static void VerifyManifestSignature(byte[] manifest, byte[] signature)
    {
        using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider())
        {
            rsa.PersistKeyInCsp = false;
            rsa.ImportParameters(new RSAParameters {
                Modulus = Convert.FromBase64String(ModulusBase64),
                Exponent = Convert.FromBase64String(ExponentBase64)
            });
            if (!rsa.VerifyData(manifest, CryptoConfig.MapNameToOID("SHA256"), signature))
                throw new CryptographicException("The development manifest signature did not match Casein's pinned update key.");
        }
    }

    private static Manifest ParseManifest(byte[] bytes)
    {
        Manifest manifest;
        try { manifest = new JavaScriptSerializer().Deserialize<Manifest>(Encoding.UTF8.GetString(bytes)); }
        catch (Exception) { throw new InvalidDataException("The development manifest is malformed."); }
        if (manifest == null || manifest.manifest_version != 1 || manifest.channel != "development" || manifest.artifacts == null)
            throw new InvalidDataException("The development manifest contract is unsupported.");
        return manifest;
    }

    private static Artifact SelectArtifact(Manifest manifest, Uri manifestUri)
    {
        Artifact match = null;
        foreach (Artifact artifact in manifest.artifacts)
        {
            if (artifact != null && artifact.app == "casein" && artifact.profile == "desktop" &&
                artifact.repo_adapter == "sqlite" && artifact.target == "windows-x86_64")
            {
                if (match != null) throw new InvalidDataException("The development manifest contains duplicate Windows artifacts.");
                match = artifact;
            }
        }
        if (match == null) throw new InvalidDataException("The development manifest has no compatible Windows artifact.");
        if (match.min_installer_metadata_version > 1 || match.size <= 0 || match.size > MaxArtifactBytes ||
            !Regex.IsMatch(match.revision ?? "", "^[0-9a-fA-F]{40}$") ||
            !Regex.IsMatch(match.sha256 ?? "", "^[0-9a-fA-F]{64}$"))
            throw new InvalidDataException("The development artifact identity is invalid.");
        RequireSecureUri(match.url, manifestUri);
        return match;
    }

    private static void DownloadArtifact(Uri uri, string destination, Artifact artifact)
    {
        RequireSecureUri(uri.AbsoluteUri, new Uri(ManifestUrl));
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
        request.AllowAutoRedirect = false;
        request.Timeout = 30000;
        request.ReadWriteTimeout = 60000;
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        {
            if (response.StatusCode != HttpStatusCode.OK) throw new IOException("Artifact server returned " + response.StatusCode + ".");
            if (response.ContentLength != artifact.size) throw new InvalidDataException("Artifact size did not match the signed manifest.");
            using (Stream input = response.GetResponseStream())
            using (FileStream output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                CopyWithLimit(input, output, artifact.size);
        }
        VerifyArtifactFile(destination, artifact);
    }

    private static void VerifyArtifactFile(string path, Artifact artifact)
    {
        FileInfo file = new FileInfo(path);
        if (!file.Exists || file.Length != artifact.size) throw new InvalidDataException("Artifact size did not match the signed manifest.");
        string hash;
        using (SHA256 sha = SHA256.Create())
        using (FileStream stream = File.OpenRead(path))
            hash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        if (!String.Equals(hash, artifact.sha256, StringComparison.OrdinalIgnoreCase))
            throw new CryptographicException("Artifact SHA-256 did not match the signed manifest.");
    }

    private static string ReadInstalledRevision()
    {
        string current = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Casein", "current.json");
        if (!File.Exists(current)) return null;
        try
        {
            Dictionary<string, object> state = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(current));
            object revision;
            return state != null && state.TryGetValue("revision", out revision) ? Convert.ToString(revision, CultureInfo.InvariantCulture) : null;
        }
        catch { return null; }
    }

    private static void RecreateSafeStage(string stage)
    {
        string root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "C")) + Path.DirectorySeparatorChar;
        string full = Path.GetFullPath(stage);
        if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unsafe staging path.");
        if (Directory.Exists(full)) Directory.Delete(full, true);
        Directory.CreateDirectory(full);
    }

    private static void ExtractSafely(string archive, string destination)
    {
        Directory.CreateDirectory(destination);
        string prefix = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        using (ZipArchive zip = ZipFile.OpenRead(archive))
        {
            foreach (ZipArchiveEntry entry in zip.Entries)
            {
                string target = Path.GetFullPath(Path.Combine(destination, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
                if (!target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Archive path traversal was rejected.");
                if (String.IsNullOrEmpty(entry.Name)) { Directory.CreateDirectory(target); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(target));
                entry.ExtractToFile(target, false);
            }
        }
    }

    private static void ValidatePackage(string root, Artifact artifact)
    {
        string installer = Path.Combine(root, "windows", "Install-Casein.ps1");
        string metadataPath = Path.Combine(root, "releases", "casein.relmeta.json");
        if (!File.Exists(installer) || !File.Exists(metadataPath)) throw new InvalidDataException("The package is missing its installer or release metadata.");
        ReleaseMetadata metadata = new JavaScriptSerializer().Deserialize<ReleaseMetadata>(File.ReadAllText(metadataPath));
        if (metadata == null || metadata.revision != artifact.revision || metadata.profile != "desktop" ||
            metadata.repo_adapter != "sqlite" || metadata.target != "windows-x86_64")
            throw new InvalidDataException("The extracted package identity did not match the signed manifest.");
    }

    private static void Install(string packageRoot)
    {
        string installer = Path.Combine(packageRoot, "windows", "Install-Casein.ps1");
        ProcessStartInfo info = new ProcessStartInfo("powershell.exe");
        info.UseShellExecute = false;
        info.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + installer + "\" -PackageRoot \"" + packageRoot + "\" -AllowUnsignedDevelopment -Launch";
        using (Process process = Process.Start(info))
        {
            process.WaitForExit();
            if (process.ExitCode != 0) throw new InvalidOperationException("The verified Casein installer exited with " + process.ExitCode + ".");
        }
    }
}
