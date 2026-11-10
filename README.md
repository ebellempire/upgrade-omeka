# upgrade-omeka

Bash script for upgrading one or more Omeka Classic installations to the latest release. Optimized for cPanel/shared hosting environments.

# how to use it

Upload the `upgrade-omeka.sh` file to your server (manually or with something like...):

```
$ wget https://raw.githubusercontent.com/ebellempire/upgrade-omeka/refs/heads/main/upgrade-omeka.sh
```

Then just run it like any shell script, including one or more arguments indicating the location of the installation(s):

```
$ bash upgrade-omeka.sh path/to/omeka
$ bash upgrade-omeka.sh path/to/omeka another/path/to/omeka
```

It's a good idea to start with a check and a dry run. Neither one changes anything:

```
$ bash upgrade-omeka.sh -c path/to/omeka          # check (--check): version, PHP, database, Installatron, disk space
$ bash upgrade-omeka.sh -n path/to/omeka          # dry run (--dry-run): exactly what an upgrade would replace
```

If the server can't make outgoing requests, download the release zip somewhere else, upload it, and point the script at it. The SHA-256 is listed on the release page on GitHub:

```
$ bash upgrade-omeka.sh --local=omeka-3.2.2.zip --sha256=9e273649b99fb81ec3b9855d3e168f1b39881760789f409beb9d34f533c3d9c3 path/to/omeka
```

Other options: `-m` (`--managed`) also upgrades sites managed by Installatron, `-t` (`--themes`) also updates the bundled themes, `-j` (`--major`) allows an upgrade across a major version (e.g. 2.x to 3.x), `-d DIR` (`--backup-dir`) picks the backup folder, and `-b PHP_BIN` (`--php`) skips PHP detection (same as in [set-omeka-php-path](https://github.com/ebellempire/set-omeka-php-path)). `-l ZIP` and `-s HASH` are short for `--local` and `--sha256`. Short options can be combined (`-nm`), long ones take their value after `=` or a space, and all options go before the paths. Run with `-h` (`--help`) for the full list.

# what it does

The script gets the release once per run: the latest from GitHub, checked against the SHA-256 digest GitHub publishes for it, or the zip you gave it with `--local`. Then, for each argument, it checks that it's a valid Omeka installation (we just look for the `bootstrap.php` file and make sure it includes the string `OMEKA_VERSION`) and runs a preflight: the installed version against the release, the site's own PHP CLI version (detected the same way as set-omeka-php-path) against the release's minimum, the database credentials in `db.ini`, write permissions, free space, and whether Installatron manages the site. A site that Installatron manages is skipped unless you add `-m`, because Installatron may not notice a manual upgrade, and its auto-update could later lay an older packaged release over yours.

If everything checks out, the script dumps the site's database tables (just the ones with the site's table prefix) with `mysqldump`. It then stages the new release with the site's `config.ini` and logs, and swaps the core files (`admin/`, `application/`, `install/`, `bootstrap.php`, `index.php` and so on) by moving the old ones into the backup folder and the new ones into place. Your `db.ini`, `.htaccess`, `files/`, `plugins/`, `themes/`, `.user.ini` and anything else in the site root that isn't part of the release are never touched. Inside `admin/`, `application/` and `install/`, files the release doesn't have stay with the old core in the backup, and the summary names any server config files among them (a per-folder `php.ini`, say, or the `admin/.htaccess` that cPanel's Directory Privacy writes) so you can copy them back. The backup's `README.txt` has the commands. Right after the swap, it runs Omeka's database migrations from the command line, since Omeka keeps the public site offline until they run. If the new code won't start, the old core is put back. If a migration fails, the database dump is restored too. Either way, the site is left exactly as it was. Bundled plugins (Exhibit Builder, Simple Pages, COinS) are replaced when the release has a newer version. Bundled themes are only replaced with `-t`, since people often edit them in place. The output while it's processing is useful but minimal. When it's done, it prints out a basic summary of what was upgraded, what was skipped, and anything you still need to do.

# what it doesn't do

The script does not upgrade plugins and themes that don't ship with Omeka (see [curatescape_utility](https://github.com/ebellempire/curatescape_utility) for a tool that does do that). It does not click the Upgrade button for bundled plugins: Omeka won't load a replaced plugin until someone upgrades it on the admin Plugins page, so when that's needed the summary tells you to log in and do it. It does not set configurations that require browser detection, such as Omeka 3.2.2's Server URL setting (the summary reminds you to set it under Settings → General). It does not change Installatron's records, which the summary also reminds you to update. It does not back up `files/`, because the upgrade never touches it and it's usually far too big. It also can't tell whether you've edited any of the stock core files, so if you ever patched Omeka in place, compare against the old core in the backup folder.

# maintenance

Backups go in `~/omeka_upgrade_backups`, one folder per site per upgrade. Each holds the old core, a `db.sql.gz` of the site's tables, and a `README.txt` with the exact commands to roll back by hand. They aren't cleaned up automatically. Once you're happy with an upgrade, remove its folder with something like `rm -rf ~/omeka_upgrade_backups/public_html_mysite-3.1.2-to-3.2.2-*`. The backup folder has to be on the same filesystem as the sites, because that's what makes the swap an instant rename. If it isn't (the check will tell you), use `-d` to pick one that is. If a run is killed partway through, a `.lock-...` folder may be left behind in the backup folder, and the script will refuse to touch that site until you `rmdir` it.
