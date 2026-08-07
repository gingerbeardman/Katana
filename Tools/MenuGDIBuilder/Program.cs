using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using DiscUtils.Gdrom;

static class Program
{
    static int Main(string[] args)
    {
        try
        {
            var opts = Parse(args);
            if (opts == null)
            {
                Console.Error.WriteLine("Usage: MenuGDIBuilder --kind gdMenu|openMenu --list <ini> --assets <menuRoot> --out <menu_gdi_dir> [--truncate true|false]");
                return 2;
            }

            Build(opts.Value);
            Console.WriteLine("OK");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ERROR: " + ex.Message);
            Console.Error.WriteLine(ex.StackTrace);
            return 1;
        }
    }

    struct Options
    {
        public string Kind;
        public string ListPath;
        public string AssetsRoot;
        public string OutDir;
        public bool Truncate;
    }

    static Options? Parse(string[] args)
    {
        string kind = null, list = null, assets = null, outDir = null;
        bool truncate = true;
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            string Next() => i + 1 < args.Length ? args[++i] : null;
            switch (a)
            {
                case "--kind": kind = Next(); break;
                case "--list": list = Next(); break;
                case "--assets": assets = Next(); break;
                case "--out": outDir = Next(); break;
                case "--truncate":
                    var t = Next();
                    truncate = t == null || !t.Equals("false", StringComparison.OrdinalIgnoreCase);
                    break;
                case "-h":
                case "--help":
                    return null;
                default:
                    Console.Error.WriteLine("Unknown arg: " + a);
                    return null;
            }
        }
        if (string.IsNullOrEmpty(kind) || string.IsNullOrEmpty(list) || string.IsNullOrEmpty(assets) || string.IsNullOrEmpty(outDir))
            return null;
        return new Options
        {
            Kind = kind,
            ListPath = list,
            AssetsRoot = assets,
            OutDir = outDir,
            Truncate = truncate
        };
    }

    static void Build(Options opts)
    {
        bool isOpen = opts.Kind.Equals("openMenu", StringComparison.OrdinalIgnoreCase)
                      || opts.Kind.Equals("openmenu", StringComparison.OrdinalIgnoreCase);
        string volId = isOpen ? "OPENMENU" : "GDMENU";
        string listName = isOpen ? "OPENMENU.INI" : "LIST.INI";

        string listText = File.ReadAllText(opts.ListPath);

        string tempRoot = Path.Combine(Path.GetTempPath(), "menugdi-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        try
        {
            string lowdataPath = Path.Combine(tempRoot, "lowdensity_data");
            string dataPath = Path.Combine(tempRoot, "data");
            string cdiPath = opts.OutDir;

            Directory.CreateDirectory(lowdataPath);
            Directory.CreateDirectory(dataPath);
            if (Directory.Exists(cdiPath))
            {
                // clean contents but keep folder
                foreach (var e in Directory.EnumerateFileSystemEntries(cdiPath))
                {
                    if (Directory.Exists(e)) Directory.Delete(e, true);
                    else File.Delete(e);
                }
            }
            else
            {
                Directory.CreateDirectory(cdiPath);
            }

            string menuData = Path.Combine(opts.AssetsRoot, "menu_data");
            string menuGdi = Path.Combine(opts.AssetsRoot, "menu_gdi");
            string menuLow = Path.Combine(opts.AssetsRoot, "menu_low_data");
            string ipbin = Path.Combine(opts.AssetsRoot, "IP.BIN");

            if (!Directory.Exists(menuData)) throw new DirectoryNotFoundException(menuData);
            if (!Directory.Exists(menuGdi)) throw new DirectoryNotFoundException(menuGdi);
            if (!File.Exists(ipbin)) throw new FileNotFoundException(ipbin);

            CopyDir(menuData, dataPath);
            CopyDir(menuGdi, cdiPath);
            if (Directory.Exists(menuLow))
                CopyDir(menuLow, lowdataPath);

            File.WriteAllText(Path.Combine(lowdataPath, listName), listText);
            File.WriteAllText(Path.Combine(dataPath, listName), listText);

            var builder = new GDromBuilder()
            {
                RawMode = false,
                TruncateData = opts.Truncate,
                VolumeIdentifier = volId
            };

            var fileList = new DirectoryInfo(lowdataPath).GetFiles().ToList();
            builder.CreateFirstTrack(Path.Combine(cdiPath, "track01.iso"), fileList);

            var cdda = new List<string>();
            string track04 = Path.Combine(cdiPath, "track04.raw");
            if (File.Exists(track04))
                cdda.Add(track04);

            var tracks = builder.BuildGDROM(dataPath, ipbin, cdda, cdiPath);
            builder.UpdateGdiFile(tracks, Path.Combine(cdiPath, "disc.gdi"));
        }
        finally
        {
            try { if (Directory.Exists(tempRoot)) Directory.Delete(tempRoot, true); } catch { }
        }
    }

    static void CopyDir(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var file in Directory.GetFiles(src))
        {
            File.Copy(file, Path.Combine(dst, Path.GetFileName(file)), true);
        }
        foreach (var dir in Directory.GetDirectories(src))
        {
            CopyDir(dir, Path.Combine(dst, Path.GetFileName(dir)));
        }
    }
}
