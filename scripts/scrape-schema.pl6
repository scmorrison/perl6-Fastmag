#!/usr/bin/env perl6
# 
# Usage: ./scripts/scrape-schema.pl6 SESSIONID
#
# edi.yml format:
# ---
# host: FASTMAG_EDI_HOST
# account: ACCOUNT_NAME
# store: STORE_NAME

use v6.d.PREVIEW;

use YAMLish;
use Cro::HTTP::Client;
use Gumbo;

sub table-names(
    $html
) {
    my @table_names = gather map -> $line {
        next unless $line ~~ / 'option value=' / && $line !~~ / '<form ' /;
        take (m/'<option value="' <(\S*)> '" ' 'selected'?  '>' \S* $ / given $line).Str;
    }, $html.lines;
}

sub request(
    :$session_id,
    :$host,
    :$account,
    :$store = 'WEB',
    :$table_name = 'accesfichesclients',
    :$output_file
) {
    my $uri  = '_mcd.ips';
    my $url  = "http://{$host}/{$uri}";
    my %body = Table => $table_name, VoirBtn => 'Voir';

    my $client = Cro::HTTP::Client.new:
        headers => [
            Origin          => "http://{$host}",
            Accept          => 'application/xhtml+xml',
            Referer         => $url,
            Accept-Encoding => 'gzip, deflate',
            Cookie          => "SessionID={$session_id}; fuid={$session_id}; Enseinge={$account}; Magasin={$store}; Utilisateur={$store}".encode('UTF-8'),
            Content-Length  => "Table={$table_name}&VoirBtn=Voir".chars.Str,
            User-Agent      => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/61.0.3163.100 Safari/537.36"
        ];

    my $resp = await $client.post: $url, content-type => 'application/x-www-form-urlencoded', :%body;
    my $body = await $resp.body-text();
    spurt $output_file, $body;
}

sub MAIN(
    $session_id,
    Bool :$refresh = False
) {

    die "edi.yml not found" unless "edi.yml".IO ~~ :e;

    my %config = load-yaml slurp "edi.yml";

    my $schema_dir = "schema".IO;

    for ['html', 'csv'] { mkdir $schema_dir.IO.child($_) }

    my $mcd_html_file = $schema_dir.IO.child('html').child('mcd.html');

    unless $mcd_html_file.IO.e || $refresh {
        request 
            :$session_id,
            host        => %config<host>,
            account     => %config<account>,
            store       => %config<store>,
            output_file => $mcd_html_file;
    }

    # Cache html generated for each table
    # and convert to csv
    for table-names($mcd_html_file) -> $table_name {

        my $output_file = $schema_dir.IO.child('html').child("{$table_name}.html");

        # Skip request when html exists unless refresh flag is set
        next when $output_file.IO ~~ :f && !$refresh;

        # Cache html
        request
            :$session_id,
            :$table_name,
            :$output_file,
            host    => %config<host>,
            account => %config<account>,
            store   => %config<store>;

        my $xml   = parse-html slurp $output_file;
        my $table = $xml.root.elements(:TAG<table>, :class<tabListe>, :RECURSE)[0];
        my @rows  = parse-html($table.Str).root.elements(:TAG<tr>, :RECURSE);
 
        my $output = 'Field;Type;Null;Key;Default;Extra';

        for @rows -> $row {
             $output ~= join ';', (~<< $row.Str.match: / 'tabListe">' <(\S*)> ' </td>' /, :g);
             $output ~= "\n";
        }

        say "Writing {$table_name}.csv";
        spurt $schema_dir.IO.child('csv').child("{$table_name}.csv"), $output;

        sleep 2;
    }

}
