package Giblog::Command::build;

use base 'Giblog::Command';

use strict;
use warnings;
use utf8;

use File::Basename 'basename';

use Pod::Simple::HTML;

sub _indentation {
  (sort map {/^(\s+)/} @{shift()})[0];
}

sub run {
  my ($self, @args) = @_;

  # API
  my $api = $self->api;

  # Read config
  my $config = $api->read_config;

  # Copy static files to public
  $api->copy_static_files_to_public;

  # Add base path to public css files
  $api->add_base_path_to_public_css_files;

  # Get files in templates directory
  my $files = $api->get_templates_files;

  for my $file (@$files) {

    my $data = {file => $file};

    # Get content from file in templates directory
    $api->get_content($data);

    # Parse POD
    if ($data->{file} =~ /(\.pm|\.pod)$/) {
      my $content = $data->{content};
      
      # PODを解析
      my $pod = $content;
      my $parser = Pod::Simple::HTML->new;
      $parser->parse_characters(1);
      $parser->strip_verbatim_indent(\&_indentation);
      $parser->output_string(\(my $output));
      $parser->strip_verbatim_indent(sub {
        my $lines = shift;
        s/^  //, s/</&lt;/g, s/>/&gt;/g for @$lines;
        return undef;
      });
      $parser->parse_string_document("$pod");
      $data->{content} = $output;
      
      # Wikiリンクを解析
      $data->{content} =~ s|\Qhttp://search.cpan.org/perldoc?\E([^"]+)|my $name = $1; $name =~ s!::!/!g; $name .= ".html"; "/$name";|ge;
      
      # Fix extension
      $data->{file} =~ s/\.pm$/.html/;
      $data->{file} =~ s/\.pod$/.html/;
      
      # Top page
      if ($data->{file} eq 'Giblog.html') {
        $data->{file} = 'index.html';
      }
    }
    # Parse Giblog syntax
    else {
      $api->parse_giblog_syntax($data);
    }
    
    # 数値文字参照を内部文字列へ変換
    $data->{content} =~ s/&#([0-9]+);/chr($1)/ge;
    
    # 見出しを二つしたの見出しにずらす(サイトタイトルをh1、ページタイトルをh2にするため)
    $data->{content} =~ s|<h4>|<h6>|g;
    $data->{content} =~ s|</h4>|</h6>|g;
    $data->{content} =~ s|<h3>|<h5>|g;
    $data->{content} =~ s|</h3>|</h5>|g;
    $data->{content} =~ s|<h2>|<h4>|g;
    $data->{content} =~ s|</h2>|</h4>|g;
    $data->{content} =~ s|<h1>|<h3>|g;
    $data->{content} =~ s|</h1>|</h3>|g;
    
    # 最初のh3をh2にする
    $data->{content} =~ s|<h3>|<h2>|;
    $data->{content} =~ s|</h3>|</h2>|;

    # h2に入るのを「名前」ではなく、その次の説明にする
    $data->{content} =~ s|<h2>.*?名前.*?</h2>.*?<p>(.+?)</p>|<h2>$1</h2>|s;

=pod
<h3><a class='u'
name="_"
>説明</a></h3>
=cut

    # WikiリンクをHTMLのリンクへ
    # \[\[([^\]]+)(|([^\]+))?\]\]
    # $3 ? qq(<a href="$3">$1</a>) : qq(<a href="/$1">$1</a>)
    my $wiki_to_html_link_cb = sub {
      my ($text, $path) = @_;
      
      if (defined $path) {
        if ($path !~ /^http/) {
          $path = "/$path.html";
        }
      }
      else {
        $path = "/$text.html";
      }
      
      my $html_link = qq(<a href="$path">$text</a>);
      
      return $html_link;
    };
    
    $data->{content} =~ s#\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]#$wiki_to_html_link_cb->($1, $2);#ge;

    # 説明の場所を先頭へ移動
    if ($data->{content} =~ s|<h3><[^>]*?>説明</a></h3>(.*?)<h3>|<h3>|s) {
      my $description = $1;
      $data->{content} =~ s|</h2>|</h2>\n$description\n|;
    }
    
    # APIリファレンスのpをdivへ
    $data->{content} =~ s|<p><a href="/mojo-api-reference.html">([^<]*?)</a></p>|<div><a href="/mojo-api-reference.html">$1</a></div>|;

    # Parse title
    $api->parse_title_from_first_h_tag($data);

    # Edit title
    my $site_title = $config->{site_title};
    if ($data->{file} eq 'index.html' || !defined $data->{title}) {
      $data->{title} = $site_title;
    }
    else {
      $data->{title} = "$data->{title} - $site_title";
    }

    # Add page link
    $api->add_page_link_to_first_h_tag($data, {root => 'index.html'});

    # Parse description
    $api->parse_description_from_first_p_tag($data);

    # Read common templates
    $api->read_common_templates($data);

    # Add meta title
    $api->add_meta_title($data);

    # Add meta description
    $api->add_meta_description($data);

    # Build entry html
    $api->build_entry($data);

    # Build whole html
    $api->build_html($data);

    # Add base path to content
    $api->add_base_path_to_content($data);

    # Write to public file
    $api->write_to_public_file($data);
  }

  # Create list page
  $self->create_list;
}

# Create all entry list page
sub create_list {
  my $self = shift;

  # API
  my $api = $self->api;

  # Config
  my $config = $api->config;

  # Template files
  my @template_files = glob $api->rel_file('templates/blog/*');
  @template_files = reverse sort @template_files;

  # Data
  my $data = {file => 'list.html'};

  # Entries
  {
    my $content;
    $content = <<'EOS';
<h2>Entries</h2>
EOS
    $content .= "<ul>\n";
    my $before_year = 0;
    for my $template_file (@template_files) {
      # Day
      my $base_name = basename $template_file;
      my ($year, $month, $mday) = $base_name =~ /^(\d{4})(\d{2})(\d{2})/;
      $month =~ s/^0//;
      $mday =~ s/^0//;

      # Year
      if ($year != $before_year) {
        $content .= <<"EOS";
  <li style="list-style:none;">
    <b>${year}</b>
  </li>
EOS
      }
      $before_year = $year;

      # File
      my $file_entry = "blog/$base_name";

      # Data
      my $data_entry = {file => $file_entry};

      # Get content
      $api->get_content($data_entry);

      # Parse title from first h tag
      $api->parse_title_from_first_h_tag($data_entry);

      # Title
      my $title = $data_entry->{title};
      unless(defined $title) {
        $title = 'No title';
      }

      # Convert all file syntax to .html
      $file_entry =~ s/\.[^\.]+$/\.html/;

      # Add list
      $content .= <<"EOS";
  <li style="list-style:none">
    $month/$mday <a href="/$file_entry">$title</a>
  </li>
EOS
    }
    $content .= "</ul>\n";

    # Set content
    $data->{content} = $content;
  }

  # Add page link
  $api->add_page_link_to_first_h_tag($data);

  # Title
  $data->{title} = "Entries - $config->{site_title}";

  # Description
  $data->{description} = "Entries of $config->{site_title}";

  # Read common templates
  $api->read_common_templates($data);

  # Add meta title
  $api->add_meta_title($data);

  # Add meta description
  $api->add_meta_description($data);

  # Build entry html
  $api->build_entry($data);

  # Build whole html
  $api->build_html($data);

  # Add base path to content
  $api->add_base_path_to_content($data);

  # Write content to public file
  my $public_file = $api->rel_file('public/list.html');
  $api->write_to_file($public_file, $data->{content});
}

sub parse_title {
  my ($api, $data) = @_;
  
  my $content = $data->{content};
  my $title;
  if ($content =~ /=head1 名前(.*?)=/s) {
    $title = $1;
    $title =~ s/^\s*//;
    $title =~ s/\s+$//;
  } 
  
  $data->{title} = $title;
}

sub parse_description {
  my ($api, $data) = @_;
  
  my $content = $data->{content};
  my $description;
  if ($content =~ /=head1 説明(.*?)=/s) {
    $description = $1;
    $description =~ s/^\s*//;
    $description =~ s/\s+$//;
    $description =~ s/B<//g;
    $description =~ s/>//g;
  } 
  
  $data->{description} = $description;
}

1;
