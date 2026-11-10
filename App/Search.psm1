Set-StrictMode -Version 2.0
function New-QaSearchIndex {
    [CmdletBinding()]param([AllowEmptyCollection()][object[]]$Records=@())
    if($null -eq ('CtQa.ReportIndex' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Globalization;
using System.Collections.Generic;
using System.Management.Automation;
namespace CtQa {
 public sealed class ReportIndex {
  sealed class Row {
   public object Original; public string Scanner, Category, Date, Time, Name, Id, Text; public int Year, Month;
  }
  readonly List<Row> rows = new List<Row>();
  static object Value(PSObject p, string name) { var v=p.Properties[name];return v==null?null:v.Value; }
  static string Text(PSObject p, string name) { var v=Value(p,name);return v==null?"":Convert.ToString(v,CultureInfo.InvariantCulture); }
  static string Label(string scanner, string name) {
   if(!String.IsNullOrWhiteSpace(name))return name.Trim();
   if(scanner=="CT_Edge")return "CT Edge";if(scanner=="CT_Flash")return "CT Flash";if(scanner=="MDP_Building")return "MDP Building";return scanner.Replace('_',' ');
  }
  static string CategoryLabel(string category) {
   switch(category){case "Daily_QA":return "Daily QA";case "Monthly_QA":return "Monthly QA - Confirmed";case "Monthly_QA/Pending_Verification":return "Monthly QA - Pending Verification";case "Acceptance_Tests":return "Acceptance Tests";default:return "Needs Review";}
  }
  public ReportIndex(object[] records) {
   foreach(object original in records) {
    if(original==null)continue;PSObject p=PSObject.AsPSObject(original);
    Row row=new Row();row.Original=original;row.Scanner=Text(p,"Scanner");row.Category=Text(p,"Category");row.Time=Text(p,"ReportTime");row.Name=Text(p,"OriginalFileName");row.Id=Text(p,"Id");
    object raw=Value(p,"ReportDate");DateTime date;
    bool valid=raw is DateTime;
    if(valid)date=((DateTime)raw).Date;else valid=DateTime.TryParseExact(raw==null?"":raw.ToString(),"yyyy-MM-dd",CultureInfo.InvariantCulture,DateTimeStyles.None,out date);
    row.Date=valid?date.ToString("yyyy-MM-dd",CultureInfo.InvariantCulture):Text(p,"ReportDate");row.Year=valid?date.Year:0;row.Month=valid?date.Month:0;
    string titleDate=valid?date.ToString("MMM dd, yyyy",CultureInfo.InvariantCulture):"Undated report";
    if(row.Time.Length>=5 && row.Time[2]==':')titleDate+=" at "+row.Time.Substring(0,5);
    string title=Label(row.Scanner,Text(p,"ScannerName"))+" - "+titleDate+" - "+CategoryLabel(row.Category);
    row.Text=title+" "+row.Name+" "+row.Date+" "+row.Time+" "+row.Scanner+" "+row.Category+" "+(valid?date.ToString("MMMM",CultureInfo.InvariantCulture):"");
    rows.Add(row);
   }
   rows.Sort(delegate(Row a,Row b) { foreach(string key in new string[]{"Date","Time","Scanner","Name","Id"}) {string x=key=="Date"?a.Date:key=="Time"?a.Time:key=="Scanner"?a.Scanner:key=="Name"?a.Name:a.Id;string y=key=="Date"?b.Date:key=="Time"?b.Time:key=="Scanner"?b.Scanner:key=="Name"?b.Name:b.Id;int c=StringComparer.OrdinalIgnoreCase.Compare(x,y);if(c!=0)return c;}return 0;});
  }
  public object[] Find(string scanner,int year,int month,string category,string query,int[] years) {
   var selected=new List<object>();var wanted=new HashSet<int>(years==null?new int[0]:years);query=(query==null?"":query).Trim();
   foreach(Row row in rows) {
    if(!String.IsNullOrEmpty(scanner)&&!String.Equals(scanner,"All",StringComparison.OrdinalIgnoreCase)&&!String.Equals(row.Scanner,scanner,StringComparison.OrdinalIgnoreCase))continue;
    if(!String.IsNullOrEmpty(category)&&!String.Equals(category,"All",StringComparison.OrdinalIgnoreCase)&&!String.Equals(row.Category,category,StringComparison.OrdinalIgnoreCase))continue;
    if(wanted.Count>0){if(row.Year==0||!wanted.Contains(row.Year))continue;}else if(year!=0&&row.Year!=year)continue;
    if(month!=0&&row.Month!=month)continue;if(query.Length>0&&row.Text.IndexOf(query,StringComparison.OrdinalIgnoreCase)<0)continue;
    selected.Add(row.Original);
   }
   return selected.ToArray();
  }
 }
}
'@
    }
    return [CtQa.ReportIndex]::new($Records)
}
Export-ModuleMember -Function New-QaSearchIndex
